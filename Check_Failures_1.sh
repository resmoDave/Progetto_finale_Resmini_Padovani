#!/bin/bash

LOG_FILE="backup.log"
API_URL="http://127.0.0.1:8000/get-email"
SENDER_EMAIL="monitor@tuodominio.it"

# Controlla se il file log esiste
if [ ! -f "$LOG_FILE" ]; then
    echo "Errore: $LOG_FILE non trovato."
    exit 1
fi

echo "--- Inizio Scansione Log per Postfix ---"

while IFS=',' read -r data server_id tipo stato dimensione durata; do
    
    if [ "$stato" == "ERROR" ]; then
        echo "[!] Errore trovato su $server_id. Recupero email..."

        # 1. Chiamata API per ottenere l'email
        RESPONSE=$(curl -s "$API_URL/$server_id")
        DEST_EMAIL=$(echo $RESPONSE | jq -r '.email')

        if [ "$DEST_EMAIL" != "null" ]; then
            
            # 2. Definizione Oggetto e Corpo
            SUBJECT="ALERT BACKUP: $server_id FALLITO"
            BODY="Il backup di tipo $tipo per il server $server_id è fallito.\nData: $data\nDimensione: $dimensione bytes\nDurata: $durata secondi."

            # 3. INVIO DIRETTO TRAMITE POSTFIX (comando sendmail)
            # Costruiamo il pacchetto email con gli header corretti
            (
              echo "To: $DEST_EMAIL"
              echo "From: $SENDER_EMAIL"
              echo "Subject: $SUBJECT"
              echo "Content-Type: text/plain; charset=UTF-8"
              echo ""
              echo -e "$BODY"
            ) | /usr/sbin/sendmail -t

            echo "    [OK] Email passata a Postfix per: $DEST_EMAIL"
        else
            echo "    [X] Impossibile trovare email per $server_id via API"
        fi
        echo "------------------------------------------------"
    fi

done < "$LOG_FILE"

echo "--- Fine Processo ---"