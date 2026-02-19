#!/bin/bash
# Script 10 - full_verification.sh
# Verifica fisica di tutti i file di backup contrassegnati come SUCCESS nel log.
# Per ogni file controlla: esistenza, leggibilità, dimensione effettiva.
# Invia una email di riepilogo per ogni server con errori rilevati.

# -------------------- CONFIGURAZIONE --------------------
API_BASE_URL="http://127.0.0.1:8000"
LOCAL_BACKUP_DIR="$(pwd)/local_backup"          # Directory base dei backup
LOG_FILE="full_verification.log"
AUDIT_LOG="audit_clean.log"                      # Log da analizzare
TMP_ERRORS="/tmp/full_verification_errors.$$"    # File temporaneo per errori

# Abilita debug (commenta per disabilitare)
DEBUG=true

# -------------------- FUNZIONI --------------------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

debug() {
    if [ "$DEBUG" = true ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [DEBUG] $1" | tee -a "$LOG_FILE"
    fi
}

# Recupera email di un server dall'API
get_email() {
    local server_id="$1"
    local url="${API_BASE_URL}/get-email/${server_id}"
    local email=""

    if command -v jq &>/dev/null; then
        email=$(curl -s --max-time 5 "$url" | jq -r '.email' 2>/dev/null)
    else
        email=$(curl -s --max-time 5 "$url" | grep -oP '"email":\s*"\K[^"]+')
    fi
    echo "$email"
}

# Invia una email di riepilogo errori per un server
send_alert() {
    local server_id="$1"
    local error_file="$2"
    if [ ! -s "$error_file" ]; then
        return
    fi

    local email=$(get_email "$server_id")
    if [ -z "$email" ]; then
        log "ERRORE: Impossibile trovare email per $server_id, salto invio alert"
        return
    fi

    local subject="[ALLERTA] Integrità backup compromessa per $server_id"
    local body="Sono stati rilevati problemi di integrità sui file di backup del server $server_id:\n\n"
    body+="$(cat "$error_file")\n"
    body+="Si prega di verificare immediatamente."

    echo -e "$body" | mail -s "$subject" "$email"
    if [ $? -eq 0 ]; then
        log "Alert inviato a $email per $server_id"
    else
        log "ERRORE: Invio mail fallito per $server_id"
    fi
}

# -------------------- INIZIO --------------------
log "===== Avvio Full Verification ====="

if [ ! -f "$AUDIT_LOG" ]; then
    log "ERRORE: File $AUDIT_LOG non trovato."
    exit 1
fi

# Pulisce file temporanei precedenti
rm -f "$TMP_ERRORS"*

# Regex per estrarre i campi dalla riga di log
# Il formato include spazi variabili e il simbolo ✅ (unicode)
# Esempio: 2026/02/09 13:21:39  | 15005  | 102.132.20.199 (srv-web-01)  | 1048576      | srv-web-01/backup_1.dat                       | ✅ SUCCESS
# Gruppi: timestamp, pid, ip, server_id, dimensione, percorso, esito
# Attenzione: l'esito può contenere "✅ SUCCESS" o "SUCCESS"
regex='^([^|]+)\|[[:space:]]*([0-9]+)[[:space:]]*\|[[:space:]]*([0-9.]+)[[:space:]]+\(([^)]+)\)[[:space:]]*\|[[:space:]]*([0-9]+)[[:space:]]*\|[[:space:]]*([^|]+)\|[[:space:]]*(.*)$'

# Variabili per tracciare il server corrente
current_server=""
error_file=""
line_count=0
success_count=0

while IFS= read -r line; do
    ((line_count++))
    # Salta righe vuote o di intestazione (che iniziano con TIMESTAMP)
    [[ -z "$line" || "$line" =~ ^TIMESTAMP ]] && continue

    if [[ "$line" =~ $regex ]]; then
        timestamp="${BASH_REMATCH[1]}"
        pid="${BASH_REMATCH[2]}"
        ip="${BASH_REMATCH[3]}"
        server_id="${BASH_REMATCH[4]}"
        dimensione_log="${BASH_REMATCH[5]}"
        percorso="${BASH_REMATCH[6]}"
        esito_raw="${BASH_REMATCH[7]}"

        # Rimuovi spazi iniziali/finali da esito
        esito=$(echo "$esito_raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        debug "Riga $line_count: server=$server_id, esito='$esito'"

        # Considera solo righe con SUCCESS (con o senza checkmark)
        if [[ "$esito" != *"SUCCESS"* ]]; then
            debug "Escluso (non SUCCESS): $esito"
            continue
        fi

        ((success_count++))

        # Se cambia il server, gestisci la chiusura del file errori precedente
        if [ "$server_id" != "$current_server" ]; then
            if [ -n "$current_server" ] && [ -f "$error_file" ]; then
                send_alert "$current_server" "$error_file"
                rm -f "$error_file"
            fi
            current_server="$server_id"
            error_file="${TMP_ERRORS}_${server_id}"
            # Assicura che il file sia vuoto all'inizio
            > "$error_file"
        fi

        # Costruisci il path completo del file
        file_path="${LOCAL_BACKUP_DIR}/${percorso}"

        debug "Verifico $file_path (dimensione attesa $dimensione_log)"

        # Verifica esistenza
        if [ ! -e "$file_path" ]; then
            echo "❌ File mancante: $percorso (dimensione attesa $dimensione_log)" >> "$error_file"
            log "MANCANTE: $percorso per $server_id"
            continue
        fi

        # Verifica leggibilità
        if [ ! -r "$file_path" ]; then
            echo "❌ File non leggibile: $percorso" >> "$error_file"
            log "NON LEGGIBILE: $percorso per $server_id"
            continue
        fi

        # Verifica dimensione effettiva
        dimensione_effettiva=$(stat -c %s "$file_path" 2>/dev/null)
        if [ $? -ne 0 ]; then
            echo "❌ Impossibile ottenere dimensione di $percorso" >> "$error_file"
            log "ERRORE STAT: $percorso per $server_id"
            continue
        fi

        if [ "$dimensione_effettiva" -ne "$dimensione_log" ]; then
            echo "❌ Dimensione errata per $percorso: attesa $dimensione_log, trovata $dimensione_effettiva" >> "$error_file"
            log "DIMENSIONE ERRATA: $percorso per $server_id (attesa $dimensione_log, trovata $dimensione_effettiva)"
            continue
        fi

        debug "OK: $percorso"
    else
        debug "Nessun match per riga $line_count: $line"
    fi
done < "$AUDIT_LOG"

# Dopo il loop, invia gli alert per l'ultimo server
if [ -n "$current_server" ] && [ -f "$error_file" ]; then
    send_alert "$current_server" "$error_file"
    rm -f "$error_file"
fi

# Pulisci eventuali file temporanei residui
rm -f "$TMP_ERRORS"*

log "===== Full Verification completata: $line_count righe lette, $success_count successi elaborati ====="