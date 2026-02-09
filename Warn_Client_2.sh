#!/bin/bash

# 1. Caricamento variabili dal file .env
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# CONFIGURAZIONE
LOG_FILE="audit_clean.log"
SERVER_API_URL="http://127.0.0.1:8000/get-email/"
TARGET_ID="srv-web-01" # Cambialo con l'ID che vuoi monitorare

echo "--- [START] Script di monitoraggio avviato ---"
echo "Log file: $LOG_FILE"
echo "Target ID: $TARGET_ID"
echo "API Server: $SERVER_API_URL"
echo "----------------------------------------------"

# Funzione per scrivere in coda
send_email_to_queue() {
    echo "[DEBUG] Aggiunta alla coda: ID=$1, Errore=$2"
    echo "$1|$2|$3|$4" >> .warn_client_queue
}

# Worker che processa la coda
process_queue() {
    while true; do
        if [ ! -s .warn_client_queue ]; then
            sleep 1
            continue
        fi

        # Legge dalla coda
        IFS='|' read -r server_id error_type file_path timestamp < .warn_client_queue
        sed -i '1d' .warn_client_queue

        echo "[PROCESS] Analizzo evento per: $server_id"

        # --- FILTRO ID ---
        if [[ "$server_id" != "$TARGET_ID" ]]; then
            echo "[SKIP] Ignoro $server_id perché non è il target ($TARGET_ID)"
            continue
        fi

        # Recupera email reale
        echo "[API] Richiesta email per $server_id..."
        recipient_email=$(curl -s "${SERVER_API_URL}${server_id}" | grep -oP '"email":\s*"\K[^\"]+')
        
        if [[ -z "$recipient_email" ]]; then
            echo "[ERROR] API non ha restituito nessuna email per $server_id!"
            continue
        fi

        echo "[MAIL] Email trovata: $recipient_email. Preparo l'invio..."

        # Creazione corpo email
        EMAIL_SUBJECT="[ALLERTA] Backup Fallito: $server_id"
        EMAIL_BODY="Dettagli Errore
        -------------------------
        Server:   $server_id
        Errore:   $error_type
        File:     $file_path
        Data:     $timestamp"

        # INVIO LOCALE
        echo "$EMAIL_BODY" | mail -s "$EMAIL_SUBJECT" "$recipient_email"
        
        if [ $? -eq 0 ]; then
            echo "[SUCCESS] Email inviata con successo a $recipient_email"
        else
            echo "[ERROR] Errore durante l'invio con il comando mail"
        fi

    done
}

# --- MONITORAGGIO LOG ---
processed_lines=0
[ -f .warn_client_offset ] && processed_lines=$(cat .warn_client_offset)

REGEX_PAREN="\(([^)]+)\)"
start_line=$((processed_lines + 1))

echo "[MONITOR] Inizio scansione log dalla riga $start_line..."

tail -F -n +$start_line "$LOG_FILE" | while read -r line; do
    ((processed_lines++))
    echo "$processed_lines" > .warn_client_offset
    
    # Se la riga contiene un errore di connessione o permessi
    if [[ "$line" == *"ERROR_CONN"* ]] || [[ "$line" == *"ERROR_PERM"* ]]; then
        echo "[FOUND] Rilevato errore nel log: $line"
        
        IFS='|' read -r timestamp pid host_field dimension file_path error_type <<< "$line"
        
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
        
        send_email_to_queue "$server_id" "$error_type" "$file_path" "$timestamp"
    fi
done &

# Avvia il worker in primo piano così vedi i log qui
process_queue