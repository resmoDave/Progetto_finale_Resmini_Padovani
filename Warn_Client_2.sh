#!/bin/bash

# 1. Caricamento variabili dal file .env
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Configurazione API MailerSend
API_URL="https://api.mailersend.com/v1/email"
LOG_FILE="audit_clean.log"
SERVER_API_URL="http://127.0.0.1:8000/get-email/"

# Funzione per scrivere in coda
send_email() {
    echo "$1|$2|$3|$4" >> .warn_client_queue
}

# Worker che processa la coda
process_queue() {
    while true; do
        if [ ! -s .warn_client_queue ]; then
            sleep 1
            continue
        fi

        IFS='|' read -r server_id error_type file_path timestamp < .warn_client_queue
        tail -n +2 .warn_client_queue > .warn_client_queue.tmp && mv .warn_client_queue.tmp .warn_client_queue

        # FILTRO DEBUG: Solo srv-web-01
        if [[ "$DEBUG" == "1" && "$server_id" != "srv-web-01" ]]; then
            echo "[DEBUG] Ignoro $server_id (cerco srv-web-01)"
            continue
        fi

        # Recupera email reale
        recipient_email=$(curl -s "${SERVER_API_URL}${server_id}" | grep -oP '"email":\s*"\K[^\"]+')
        
        if [[ -z "$recipient_email" ]]; then
            echo "[WARN] Email non trovata per $server_id."
            continue
        fi

        echo "[INFO] Invio API a $recipient_email per server $server_id..."

        # Creazione JSON
        JSON_DATA=$(cat <<EOF
{
    "from": { "email": "$FROM_EMAIL", "name": "Supporto Tecnico" },
    "to": [ { "email": "$recipient_email" } ],
    "subject": "[AVVISO] Errore Backup $server_id",
    "text": "Errore $error_type su $server_id. File: $file_path",
    "html": "<h3>Allerta Backup</h3><p>Server: $server_id<br>Errore: $error_type</p>"
}
EOF
)

        # Invio API
        curl -s -X POST "$API_URL" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $API_TOKEN" \
            -d "$JSON_DATA"

        # CHIUSURA DOPO INVIO IN DEBUG
        if [[ "$DEBUG" == "1" && "$server_id" == "srv-web-01" ]]; then
            echo "[DEBUG] Test srv-web-01 completato. Esco."
            pkill -P $$
            exit 0
        fi
    done
}

# --- MONITORAGGIO LOG ---
processed_lines=0
[ -f .warn_client_offset ] && processed_lines=$(cat .warn_client_offset)

# Definizione Regex fuori dall'IF per evitare errori di sintassi (Linea 95 FIX)
REGEX_PAREN="\(([^)]+)\)"

tail -Fn0 "$LOG_FILE" | awk -v skip_lines="$processed_lines" 'NR > skip_lines {print}' | while read -r line; do
    ((processed_lines++))
    echo "$processed_lines" > .warn_client_offset
    
    if echo "$line" | grep -qE "ERROR_CONN|ERROR_PERM"; then
        timestamp=$(echo "$line" | awk -F'|' '{print $1}' | xargs)
        host_field=$(echo "$line" | awk -F'|' '{print $3}' | xargs)
        file_path=$(echo "$line" | awk -F'|' '{print $5}' | xargs)
        error_type=$(echo "$line" | awk -F'|' '{print $6}' | xargs)
        
        # Uso della variabile REGEX per evitare l'errore di Bash
        if [[ "$host_field" =~ $REGEX_PAREN ]]; then
            server_id="${BASH_REMATCH[1]}"
        else
            server_id=$(echo "$file_path" | cut -d'/' -f1)
            [[ "$server_id" == "source_chaos" ]] && server_id=$(echo "$file_path" | cut -d'/' -f2)
        fi
        send_email "$server_id" "$error_type" "$file_path" "$timestamp"
    fi
done &

process_queue