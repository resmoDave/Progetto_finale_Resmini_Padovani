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
        # Rimuove la prima riga processata in modo atomico (più sicuro)
        sed -i '1d' .warn_client_queue

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

        if [[ "$DEBUG" == "1" && "$server_id" == "srv-web-01" ]]; then
            echo "[DEBUG] Test srv-web-01 completato. Esco."
            pkill -P $$
            exit 0
        fi
    done
}

# --- MONITORAGGIO LOG CORRETTO ---
processed_lines=0
[ -f .warn_client_offset ] && processed_lines=$(cat .warn_client_offset)

# Regex precompilata
REGEX_PAREN="\(([^)]+)\)"

# FIX IMPORTANTE:
# 1. Calcoliamo la riga da cui partire (+1 perché tail parte da 1, non 0)
start_line=$((processed_lines + 1))

# 2. Usiamo 'tail -n +$start_line' per dire "inizia dalla riga X del file"
#    e aggiungiamo -F per seguire i nuovi dati.
# 3. Abbiamo rimosso awk per evitare il blocco logico.
tail -F -n +$start_line "$LOG_FILE" | while read -r line; do
    
    # Incremento contatore e salvataggio
    ((processed_lines++))
    echo "$processed_lines" > .warn_client_offset
    
    # Parsing veloce in Bash senza chiamare grep/awk esterni (ottimizzazione CPU)
    if [[ "$line" == *"ERROR_CONN"* ]] || [[ "$line" == *"ERROR_PERM"* ]]; then
        
        # Estrazione campi usando IFS (molto più veloce di awk '{print $1}')
        IFS='|' read -r timestamp pid host_field dimension file_path error_type <<< "$line"
        
        # Pulizia spazi bianchi (trim)
        timestamp=$(echo "$timestamp" | xargs)
        host_field=$(echo "$host_field" | xargs)
        file_path=$(echo "$file_path" | xargs)
        error_type=$(echo "$error_type" | xargs)

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