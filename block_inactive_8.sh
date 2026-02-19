#!/bin/bash
# Script 08 - block_inactive_8.sh
# Legge audit_clean.log, verifica lo stato di ogni server via API,
# e blocca con iptables gli IP dei client non attivi (non paganti)

# -------------------- CONFIGURAZIONE --------------------
API_BASE_URL="http://127.0.0.1:8000"
LOG_FILE="whitelist.log"
AUDIT_LOG="audit_clean.log"
IPTABLES_CHAIN="INPUT"
IPTABLES_RULE_COMMENT="BLOCK_INACTIVE"

# Modalità dry-run (solo simulazione, senza bloccare realmente)
DRY_RUN=false
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "⚠️  Modalità DRY RUN: nessun blocco verrà applicato."
fi

# -------------------- FUNZIONI --------------------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Verifica se l'utente è root (necessario per iptables)
check_root() {
    if [[ $EUID -ne 0 ]]; then
        if [[ "$DRY_RUN" == false ]]; then
            echo "❌ ERRORE: Questo script deve essere eseguito come root per modificare iptables."
            echo "   Rilancialo con sudo o come utente root."
            echo "   Per una simulazione senza blocchi, usa: $0 --dry-run"
            exit 1
        else
            log "⚠️  DRY RUN: saltato controllo root (non verranno applicati blocchi)."
        fi
    fi
}

# Verifica se un IP è già bloccato
is_ip_blocked() {
    local ip="$1"
    iptables -C "$IPTABLES_CHAIN" -s "$ip" -j DROP -m comment --comment "$IPTABLES_RULE_COMMENT" 2>/dev/null
    return $?
}

# Blocca un IP con iptables (solo se non dry-run)
block_ip() {
    local ip="$1"
    local server_id="$2"
    if [[ "$DRY_RUN" == true ]]; then
        log "🔍 DRY RUN: blocco IP $ip (server $server_id) simulato."
        return
    fi

    if is_ip_blocked "$ip"; then
        log "IP $ip già bloccato (server $server_id). Skippo."
        return
    fi
    iptables -A "$IPTABLES_CHAIN" -s "$ip" -j DROP -m comment --comment "$IPTABLES_RULE_COMMENT"
    if [ $? -eq 0 ]; then
        log "🔥 BLOCCO APPLICATO: IP $ip (server $server_id) aggiunto a iptables."
    else
        log "ERRORE: Impossibile bloccare $ip (server $server_id)."
    fi
}

# Recupera lo stato di un server dall'API
get_server_status() {
    local server_id="$1"
    local url="${API_BASE_URL}/get-email/${server_id}"
    local active=""

    if command -v jq &>/dev/null; then
        active=$(curl -s --max-time 5 "$url" | jq -r '.active' 2>/dev/null)
    else
        active=$(curl -s --max-time 5 "$url" | grep -oP '"active":\s*\K[0-9]+')
    fi
    echo "$active"
}

# -------------------- INIZIO --------------------
check_root

log "===== Avvio scansione $AUDIT_LOG per client inattivi ====="

if [ ! -f "$AUDIT_LOG" ]; then
    log "ERRORE: File $AUDIT_LOG non trovato."
    exit 1
fi

# Regex per estrarre IP e server_id dal formato:
# " 102.132.20.199 (srv-web-01)  |"
regex='[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)[[:space:]]+\(([^)]+)\)[[:space:]]*\|'

# Dichiara array associativo per tracciare IP/server già processati
declare -A processed

while IFS= read -r line; do
    # Salta righe vuote o intestazione
    [[ -z "$line" || "$line" =~ ^TIMESTAMP ]] && continue

    if [[ "$line" =~ $regex ]]; then
        IP="${BASH_REMATCH[1]}"
        SERVER_ID="${BASH_REMATCH[2]}"
        
        # Evita di processare più volte lo stesso server (opzionale)
        key="${SERVER_ID}|${IP}"
        [[ -n "${processed[$key]}" ]] && continue
        processed["$key"]=1

        log "Trovato accesso: $SERVER_ID da IP $IP"

        # Recupera stato attivo
        ACTIVE=$(get_server_status "$SERVER_ID")
        if [ -z "$ACTIVE" ]; then
            log "⚠️  Impossibile ottenere stato per $SERVER_ID (API non raggiungibile o ID sconosciuto)."
            continue
        fi

        if [ "$ACTIVE" -eq 0 ]; then
            log "❌ Client $SERVER_ID NON ATTIVO. Procedo con blocco IP $IP."
            block_ip "$IP" "$SERVER_ID"
        else
            log "✅ Client $SERVER_ID attivo. Nessun blocco."
        fi
    fi
done < "$AUDIT_LOG"

log "===== Scansione completata ====="