#!/bin/bash
# ============================================================================
# block_inactive_8.sh
# ============================================================================
# DESCRIZIONE:
#   Script di sicurezza che blocca gli IP dei client non attivi (non paganti)
#   utilizzando iptables. Legge il file audit_clean.log per identificare gli
#   IP dei server, verifica il loro stato tramite API REST, e applica blocchi
#   firewall ai server inattivi.
#
# UTILIZZO:
#   sudo ./block_inactive_8.sh           # Esecuzione reale (richiede root)
#   ./block_inactive_8.sh --dry-run      # Simulazione senza applicare blocchi
#
# FUNZIONALITÀ:
#   - Parsing del log per estrarre IP e server ID
#   - Verifica stato attivo tramite API
#   - Blocco IP con iptables per client inattivi
#   - Supporto modalità dry-run per test
#
# COMANDI BASH UTILIZZATI:
#   - iptables: firewall Linux per gestire regole di rete
#   - $EUID: effective user ID (0 = root)
#   - BASH_REMATCH: array con i match delle regex
#   - declare -A: array associativo per tracciare elementi processati
# ============================================================================

# -------------------- CONFIGURAZIONE --------------------
# URL base dell'API per verificare lo stato dei server
API_BASE_URL="http://127.0.0.1:8000"

# File di log delle operazioni
LOG_FILE="whitelist.log"

# File di audit da analizzare
AUDIT_LOG="audit_clean.log"

# Configurazione iptables
# INPUT: catena per il traffico in ingresso
IPTABLES_CHAIN="INPUT"
# Commento per identificare le regole create da questo script
IPTABLES_RULE_COMMENT="BLOCK_INACTIVE"

# Modalità dry-run (simulazione)
# Utile per testare senza applicare realmente i blocchi
DRY_RUN=false
# [[ ]]: test esteso, supporta pattern matching
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "⚠️  Modalità DRY RUN: nessun blocco verrà applicato."
fi

# -------------------- FUNZIONI --------------------

# Funzione di logging con timestamp
# tee -a: scrive su stdout e append su file
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Verifica se lo script è eseguito come root
# iptables richiede privilegi amministrativi
check_root() {
    # $EUID: Effective User ID
    # -ne 0: diverso da zero (root)
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

# Verifica se un IP è già bloccato in iptables
# Argomenti: $1 = IP da verificare
# Restituisce: 0 se bloccato, 1 se non bloccato
is_ip_blocked() {
    local ip="$1"
    # iptables -C: check - verifica se una regola esiste
    # -s "$ip": source IP
    # -j DROP: azione DROP (scarta il traffico)
    # -m comment --comment: aggiunge un commento alla regola
    iptables -C "$IPTABLES_CHAIN" -s "$ip" -j DROP -m comment --comment "$IPTABLES_RULE_COMMENT" 2>/dev/null
    # return: restituisce l'exit code di iptables
    return $?
}

# Blocca un IP con iptables
# Argomenti: $1 = IP, $2 = server_id
block_ip() {
    local ip="$1"
    local server_id="$2"
    
    # In modalità dry-run, simula solo l'azione
    if [[ "$DRY_RUN" == true ]]; then
        log "🔍 DRY RUN: blocco IP $ip (server $server_id) simulato."
        return
    fi

    # Verifica se già bloccato per evitare duplicati
    if is_ip_blocked "$ip"; then
        log "IP $ip già bloccato (server $server_id). Skippo."
        return
    fi
    
    # iptables -A: append - aggiunge regola in fondo alla catena
    iptables -A "$IPTABLES_CHAIN" -s "$ip" -j DROP -m comment --comment "$IPTABLES_RULE_COMMENT"
    
    if [ $? -eq 0 ]; then
        log "🔥 BLOCCO APPLICATO: IP $ip (server $server_id) aggiunto a iptables."
    else
        log "ERRORE: Impossibile bloccare $ip (server $server_id)."
    fi
}

# Recupera lo stato attivo di un server dall'API
# Argomenti: $1 = server_id
# Restituisce: 1 se attivo, 0 se inattivo, vuoto se errore
get_server_status() {
    local server_id="$1"
    local url="${API_BASE_URL}/get-email/${server_id}"
    local active=""

    # Usa jq se disponibile, altrimenti grep
    if command -v jq &>/dev/null; then
        # jq -r '.active': estrae il campo active (raw output)
        active=$(curl -s --max-time 5 "$url" | jq -r '.active' 2>/dev/null)
    else
        # grep -oP: estrae il valore numerico del campo active
        # '"active":\s*\K[0-9]+': matcha il valore dopo "active":
        active=$(curl -s --max-time 5 "$url" | grep -oP '"active":\s*\K[0-9]+')
    fi
    echo "$active"
}

# -------------------- INIZIO ESECUZIONE --------------------
check_root

log "===== Avvio scansione $AUDIT_LOG per client inattivi ====="

# Verifica esistenza file di audit
if [ ! -f "$AUDIT_LOG" ]; then
    log "ERRORE: File $AUDIT_LOG non trovato."
    exit 1
fi

# Regex per estrarre IP e server_id dal formato del log:
# Esempio: " 102.132.20.199 (srv-web-01)  |"
# [[:space:]]*: zero o più spazi
# ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+): gruppo 1 - indirizzo IP
# \(: parentesi aperta letterale
# ([^)]+): gruppo 2 - tutto ciò che non è parentesi chiusa (server ID)
# \): parentesi chiusa letterale
regex='[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)[[:space:]]+\(([^)]+)\)[[:space:]]*\|'

# Array associativo per evitare duplicati
# Traccia le coppie SERVER_ID|IP già processate
declare -A processed

# Legge il file riga per riga
while IFS= read -r line; do
    # Salta righe vuote o intestazione
    # ||: OR logico
    # =~ ^TIMESTAMP: regex che matcha l'inizio dell'header
    [[ -z "$line" || "$line" =~ ^TIMESTAMP ]] && continue

    # =~: operatore di regex matching
    if [[ "$line" =~ $regex ]]; then
        # BASH_REMATCH: array contenente i gruppi di cattura
        # [0]: match completo
        # [1]: primo gruppo (IP)
        # [2]: secondo gruppo (server_id)
        IP="${BASH_REMATCH[1]}"
        SERVER_ID="${BASH_REMATCH[2]}"
        
        # Evita di processare più volte lo stesso server
        key="${SERVER_ID}|${IP}"
        # -n: vero se la stringa non è vuota
        [[ -n "${processed[$key]}" ]] && continue
        processed["$key"]=1

        log "Trovato accesso: $SERVER_ID da IP $IP"

        # Verifica stato attivo tramite API
        ACTIVE=$(get_server_status "$SERVER_ID")
        if [ -z "$ACTIVE" ]; then
            log "⚠️  Impossibile ottenere stato per $SERVER_ID (API non raggiungibile o ID sconosciuto)."
            continue
        fi

        # Se active = 0, il client è inattivo (non pagante)
        if [ "$ACTIVE" -eq 0 ]; then
            log "❌ Client $SERVER_ID NON ATTIVO. Procedo con blocco IP $IP."
            block_ip "$IP" "$SERVER_ID"
        else
            log "✅ Client $SERVER_ID attivo. Nessun blocco."
        fi
    fi
done < "$AUDIT_LOG"

log "===== Scansione completata ====="