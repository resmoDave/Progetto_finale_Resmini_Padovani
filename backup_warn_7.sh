#!/bin/bash

# Carica variabili d'ambiente dal file .env (opzionale)
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# -------------------- CONFIGURAZIONE --------------------
LOCAL_BACKUP_DIR="$(pwd)/local_backup"      # Directory principale dei backup (creata dallo script di generazione)
API_BASE_URL="http://127.0.0.1:8000"        # Endpoint base del server API Python
API_GET_EMAIL="$API_BASE_URL/get-email"     # Endpoint per ottenere email (es: /get-email/srv-web-01)
MAX_AGE_DAYS=7                               # Soglia di giorni per backup recente
LOG_FILE="backup_check.log"                  # File di log delle operazioni

# Lista completa dei server (come definita in server_api.py)
ALL_CLIENTS=(
    "srv-web-01" "srv-web-02" "srv-web-03" "srv-web-04" "srv-web-05"
    "srv-db-01"  "srv-db-02"  "srv-db-03"
)

# -------------------- FUNZIONI --------------------
# Log con timestamp
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Recupera l'email associata a un server chiamando l'API
# Restituisce l'email o stringa vuota in caso di errore
get_email_for_server() {
    local server_id="$1"
    local url="${API_GET_EMAIL}/${server_id}"
    local email=""

    # Tentativo con jq (se installato) altrimenti con grep
    if command -v jq &>/dev/null; then
        email=$(curl -s --max-time 5 "$url" | jq -r '.email' 2>/dev/null)
        [[ "$email" == "null" ]] && email=""
    else
        # Fallback: estrae il valore del campo "email" con grep Perl‑compatible
        email=$(curl -s --max-time 5 "$url" | grep -oP '"email":\s*"\K[^"]+')
    fi

    echo "$email"
}

# Invia un'email di allerta tramite il comando mail
send_alert() {
    local server_id="$1"
    local last_backup="$2"
    local age_days="$3"
    local recipient_email="$4"

    local subject="[ALLERTA] Backup non recente per $server_id"
    local body="Dettagli
----------------------
Server: $server_id
Ultimo backup: ${last_backup:-NESSUN BACKUP}
Età del backup: ${age_days:-N/A} giorni
Soglia: $MAX_AGE_DAYS giorni

Azione richiesta: Verificare lo stato dei backup.

Questa mail è stata generata automaticamente dal sistema di monitoraggio backup."

    echo "$body" | mail -s "$subject" "$recipient_email"
    if [ $? -eq 0 ]; then
        log "Mail inviata con successo a $recipient_email per $server_id"
    else
        log "ERRORE: Invio mail fallito per $server_id (destinatario: $recipient_email)"
    fi
}

# -------------------- CONTROLLO PRINCIPALE --------------------
log "===== Avvio controllo backup ====="

for SERVER in "${ALL_CLIENTS[@]}"; do
    log "Controllo server: $SERVER"

    # 1. Determina l'email del destinatario
    EMAIL=$(get_email_for_server "$SERVER")
    if [ -z "$EMAIL" ]; then
        log "ERRORE: Impossibile ottenere email per $SERVER (API non raggiungibile o server non trovato). Skippo."
        continue
    fi
    log "Email destinatario: $EMAIL"

    # 2. Trova il backup più recente per questo server
    BACKUP_DIR="${LOCAL_BACKUP_DIR}/${SERVER}"
    if [ ! -d "$BACKUP_DIR" ]; then
        log "WARN: Directory $BACKUP_DIR non esiste. Nessun backup presente."
        last_file="NESSUN BACKUP"
        age_days="N/A"
    else
        # Cerca il file più recente (maxdepth 1 per evitare sottodirectory)
        last_file=$(find "$BACKUP_DIR" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
        if [ -z "$last_file" ]; then
            log "WARN: Nessun file di backup trovato in $BACKUP_DIR"
            last_file="NESSUN BACKUP"
            age_days="N/A"
        else
            # Calcola l'età in giorni
            last_mtime=$(stat -c %Y "$last_file")
            current_time=$(date +%s)
            age_seconds=$((current_time - last_mtime))
            age_days=$((age_seconds / 86400))
            log "Ultimo backup: $last_file (modificato $age_days giorni fa)"
        fi
    fi

    # 3. Verifica se supera la soglia o manca
    if [ "$last_file" = "NESSUN BACKUP" ] || [ "$age_days" -gt "$MAX_AGE_DAYS" ]; then
        log "ALLERTA: Backup per $SERVER non recente (età: $age_days giorni). Invio mail..."
        send_alert "$SERVER" "$last_file" "$age_days" "$EMAIL"
    else
        log "OK: Backup per $SERVER recente (età: $age_days giorni). Nessuna azione."
    fi
done

log "===== Controllo completato ====="