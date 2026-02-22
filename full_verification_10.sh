#!/bin/bash
# ============================================================================
# full_verification_10.sh
# ============================================================================
# DESCRIZIONE:
#   Script di verifica integrità dei backup. Analizza il file audit_clean.log
#   per trovare tutti i backup contrassegnati come SUCCESS e verifica fisicamente:
#   - Esistenza del file su disco
#   - Leggibilità del file (permessi)
#   - Corrispondenza della dimensione dichiarata nel log
#
# UTILIZZO:
#   ./full_verification_10.sh
#
# FUNZIONALITÀ:
#   - Parsing del log con regex complessa
#   - Verifica fisica di ogni file di backup
#   - Raggruppamento errori per server
#   - Invio email di alert per ogni server con problemi
#
# COMANDI BASH UTILIZZATI:
#   - stat -c %s: ottiene dimensione file in bytes
#   - BASH_REMATCH: array con i match delle regex
#   - $$: PID del processo corrente (per nomi file univoci)
#   - > file: tronca/crea file vuoto
#   - echo -e: interpreta sequenze escape (\n, \t)
# ============================================================================

# -------------------- CONFIGURAZIONE --------------------
# URL base dell'API per recuperare le email
API_BASE_URL="http://127.0.0.1:8000"

# Directory base dove sono memorizzati i backup
LOCAL_BACKUP_DIR="$(pwd)/local_backup"

# File di log delle operazioni di verifica
LOG_FILE="full_verification.log"

# File di audit da analizzare
AUDIT_LOG="audit_clean.log"

# File temporaneo per accumulare errori
# $$: variabile speciale contenente il PID del processo corrente
# Utile per creare nomi univoci e evitare conflitti
TMP_ERRORS="/tmp/full_verification_errors.$$"

# Flag per abilitare output di debug
# Commenta la riga per disabilitare
DEBUG=true

# -------------------- FUNZIONI --------------------

# Funzione di logging standard con timestamp
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Funzione di logging debug (solo se DEBUG=true)
debug() {
    if [ "$DEBUG" = true ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [DEBUG] $1" | tee -a "$LOG_FILE"
    fi
}

# Recupera l'email di un server dall'API REST
# Argomenti: $1 = server_id
# Restituisce: l'email o stringa vuota
get_email() {
    local server_id="$1"
    local url="${API_BASE_URL}/get-email/${server_id}"
    local email=""

    # Usa jq se disponibile, altrimenti grep
    if command -v jq &>/dev/null; then
        email=$(curl -s --max-time 5 "$url" | jq -r '.email' 2>/dev/null)
    else
        email=$(curl -s --max-time 5 "$url" | grep -oP '"email":\s*"\K[^"]+')
    fi
    echo "$email"
}

# Invia email di alert per un server con errori
# Argomenti: $1 = server_id, $2 = file contenente gli errori
send_alert() {
    local server_id="$1"
    local error_file="$2"
    
    # -s: verifica se il file esiste E ha dimensione > 0
    # Se non ci sono errori, non invia nulla
    if [ ! -s "$error_file" ]; then
        return
    fi

    # Recupera l'email del destinatario
    local email=$(get_email "$server_id")
    if [ -z "$email" ]; then
        log "ERRORE: Impossibile trovare email per $server_id, salto invio alert"
        return
    fi

    local subject="[ALLERTA] Integrità backup compromessa per $server_id"
    
    # Costruzione corpo email
    # \n: newline
    # +=: append alla variabile (bash)
    local body="Sono stati rilevati problemi di integrità sui file di backup del server $server_id:\n\n"
    body+="$(cat "$error_file")\n"
    body+="Si prega di verificare immediatamente."

    # echo -e: interpreta le sequenze escape (\n)
    echo -e "$body" | mail -s "$subject" "$email"
    
    if [ $? -eq 0 ]; then
        log "Alert inviato a $email per $server_id"
    else
        log "ERRORE: Invio mail fallito per $server_id"
    fi
}

# -------------------- INIZIO ESECUZIONE --------------------
log "===== Avvio Full Verification ====="

# Verifica esistenza del file di audit
if [ ! -f "$AUDIT_LOG" ]; then
    log "ERRORE: File $AUDIT_LOG non trovato."
    exit 1
fi

# Pulisce file temporanei da esecuzioni precedenti
# *: wildcard per matchare tutti i file che iniziano con il pattern
rm -f "$TMP_ERRORS"*

# Regex complessa per estrarre i campi dalla riga di log
# Formato: timestamp | pid | IP (server_id) | dimensione | percorso | esito
#
# Spiegazione dei gruppi di cattura:
# ^([^|]+)                    - Gruppo 1: timestamp (tutto fino al primo |)
# \|[[:space:]]*([0-9]+)      - Gruppo 2: PID (numeri dopo il separatore)
# \|[[:space:]]*([0-9.]+)     - Gruppo 3: IP (numeri e punti)
# [[:space:]]+\(([^)]+)\)     - Gruppo 4: server_id (tra parentesi)
# \|[[:space:]]*([0-9]+)      - Gruppo 5: dimensione
# \|[[:space:]]*([^|]+)       - Gruppo 6: percorso
# \|[[:space:]]*(.*)$         - Gruppo 7: esito (tutto il resto)
regex='^([^|]+)\|[[:space:]]*([0-9]+)[[:space:]]*\|[[:space:]]*([0-9.]+)[[:space:]]+\(([^)]+)\)[[:space:]]*\|[[:space:]]*([0-9]+)[[:space:]]*\|[[:space:]]*([^|]+)\|[[:space:]]*(.*)$'

# Variabili per tracciare il server corrente e accumulare errori
current_server=""
error_file=""
line_count=0
success_count=0

# Legge il file riga per riga
while IFS= read -r line; do
    # (( )): aritmetica bash - incrementa contatore
    ((line_count++))
    
    # Salta righe vuote o intestazione
    [[ -z "$line" || "$line" =~ ^TIMESTAMP ]] && continue

    # Applica la regex alla riga
    if [[ "$line" =~ $regex ]]; then
        # Estrae i gruppi di cattura tramite BASH_REMATCH
        timestamp="${BASH_REMATCH[1]}"
        pid="${BASH_REMATCH[2]}"
        ip="${BASH_REMATCH[3]}"
        server_id="${BASH_REMATCH[4]}"
        dimensione_log="${BASH_REMATCH[5]}"
        percorso="${BASH_REMATCH[6]}"
        esito_raw="${BASH_REMATCH[7]}"

        # Rimuove spazi iniziali/finali dall'esito
        # sed 's/^[[:space:]]*//': rimuove spazi iniziali
        # s/[[:space:]]*$//: rimuove spazi finali
        esito=$(echo "$esito_raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        debug "Riga $line_count: server=$server_id, esito='$esito'"

        # Considera solo righe con SUCCESS (con o senza emoji ✅)
        # *SUCCESS*: pattern matching - qualsiasi stringa contenente "SUCCESS"
        if [[ "$esito" != *"SUCCESS"* ]]; then
            debug "Escluso (non SUCCESS): $esito"
            continue
        fi

        ((success_count++))

        # Gestione cambio server
        # Quando si cambia server, invia alert per il server precedente
        if [ "$server_id" != "$current_server" ]; then
            if [ -n "$current_server" ] && [ -f "$error_file" ]; then
                send_alert "$current_server" "$error_file"
                rm -f "$error_file"
            fi
            current_server="$server_id"
            error_file="${TMP_ERRORS}_${server_id}"
            # > "$error_file": crea file vuoto (tronca se esiste)
            > "$error_file"
        fi

        # Costruisce il path completo del file
        file_path="${LOCAL_BACKUP_DIR}/${percorso}"

        debug "Verifico $file_path (dimensione attesa $dimensione_log)"

        # VERIFICA 1: Esistenza file
        # -e: vero se il file esiste (qualsiasi tipo)
        if [ ! -e "$file_path" ]; then
            echo "❌ File mancante: $percorso (dimensione attesa $dimensione_log)" >> "$error_file"
            log "MANCANTE: $percorso per $server_id"
            continue
        fi

        # VERIFICA 2: Leggibilità file
        # -r: vero se il file è leggibile (permessi)
        if [ ! -r "$file_path" ]; then
            echo "❌ File non leggibile: $percorso" >> "$error_file"
            log "NON LEGGIBILE: $percorso per $server_id"
            continue
        fi

        # VERIFICA 3: Dimensione file
        # stat -c %s: ottiene la dimensione in bytes
        dimensione_effettiva=$(stat -c %s "$file_path" 2>/dev/null)
        
        if [ $? -ne 0 ]; then
            echo "❌ Impossibile ottenere dimensione di $percorso" >> "$error_file"
            log "ERRORE STAT: $percorso per $server_id"
            continue
        fi

        # -ne: not equal (confronto numerico)
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

# Invia alert per l'ultimo server processato
if [ -n "$current_server" ] && [ -f "$error_file" ]; then
    send_alert "$current_server" "$error_file"
    rm -f "$error_file"
fi

# Pulizia file temporanei residui
rm -f "$TMP_ERRORS"*

log "===== Full Verification completata: $line_count righe lette, $success_count successi elaborati ====="