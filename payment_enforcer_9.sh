#!/bin/bash
# Script 09 - payment_enforcer.sh
# Gestione insoluti: invio solleciti email e cancellazione dati dopo X giorni.

# -------------------- CONFIGURAZIONE --------------------
API_BASE_URL="http://127.0.0.1:8000"
LOCAL_BACKUP_DIR="$(pwd)/local_backup"
INACTIVE_STATE_DIR="$(pwd)/inactive_state"   # Directory per tracciare inattività
LOG_FILE="payment_enforcer.log"
MAX_INACTIVE_DAYS=30                          # Giorni di insoluto prima della cancellazione
EMAIL_SUBJECT_PREFIX="[SOLLECITO PAGAMENTO]"

# Crea directory di stato se non esiste
mkdir -p "$INACTIVE_STATE_DIR"

# -------------------- FUNZIONI --------------------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

get_server_status() {
    local server_id="$1"
    local url="${API_BASE_URL}/get-email/${server_id}"
    local active=""
    local email=""

    response=$(curl -s --max-time 5 "$url")
    if [ $? -ne 0 ] || [ -z "$response" ]; then
        log "ERRORE: API non raggiungibile per $server_id"
        echo "ERROR"
        return
    fi

    if command -v jq &>/dev/null; then
        active=$(echo "$response" | jq -r '.active' 2>/dev/null)
        email=$(echo "$response" | jq -r '.email' 2>/dev/null)
    else
        active=$(echo "$response" | grep -oP '"active":\s*\K[0-9]+')
        email=$(echo "$response" | grep -oP '"email":\s*"\K[^"]+')
    fi

    if [[ -z "$active" || -z "$email" ]]; then
        log "ERRORE: Risposta API malformata per $server_id"
        echo "ERROR"
        return
    fi

    echo "$active|$email"
}

send_email() {
    local server_id="$1"
    local email="$2"
    local days_inactive="$3"
    local subject="$EMAIL_SUBJECT_PREFIX $server_id"
    local body="Gentile cliente,

risulta che il server $server_id non è in regola con i pagamenti.
Giorni di insoluto: $days_inactive

La preghiamo di regolarizzare la sua posizione per evitare la cancellazione dei suoi dati dopo $MAX_INACTIVE_DAYS giorni di insoluto.

Cordiali saluti,
Il team di gestione"

    echo "$body" | mail -s "$subject" "$email"
    if [ $? -eq 0 ]; then
        log "Email inviata a $email per $server_id (insoluto da $days_inactive giorni)"
        return 0
    else
        log "ERRORE: Invio email fallito per $server_id"
        return 1
    fi
}

delete_server_data() {
    local server_id="$1"
    local backup_path="$LOCAL_BACKUP_DIR/$server_id"
    if [ -d "$backup_path" ]; then
        log "CANCELLAZIONE dati per $server_id (insoluto superato $MAX_INACTIVE_DAYS giorni)"
        # Per cancellazione sicura si potrebbe usare shred, qui usiamo rm -rf
        rm -rf "$backup_path"
        if [ $? -eq 0 ]; then
            log "Dati cancellati con successo per $server_id"
            # Rimuovi anche i file di stato
            rm -f "$INACTIVE_STATE_DIR/${server_id}.start" "$INACTIVE_STATE_DIR/${server_id}.lastmail"
        else
            log "ERRORE: Cancellazione fallita per $server_id"
        fi
    else
        log "Directory $backup_path non esistente, salto cancellazione"
    fi
}

# -------------------- MAIN --------------------
log "===== Avvio Payment Enforcer ====="

# Lista server (può essere ottenuta dinamicamente dall'API /all-emails)
ALL_SERVERS=("srv-web-01" "srv-web-02" "srv-web-03" "srv-web-04" "srv-web-05" "srv-db-01" "srv-db-02" "srv-db-03")

for SERVER in "${ALL_SERVERS[@]}"; do
    log "Processo server: $SERVER"

    STATUS=$(get_server_status "$SERVER")
    if [ "$STATUS" = "ERROR" ]; then
        continue
    fi

    ACTIVE=$(echo "$STATUS" | cut -d'|' -f1)
    EMAIL=$(echo "$STATUS" | cut -d'|' -f2)

    STATE_FILE="$INACTIVE_STATE_DIR/${SERVER}.start"
    LAST_MAIL_FILE="$INACTIVE_STATE_DIR/${SERVER}.lastmail"
    TODAY=$(date +%s)

    if [ "$ACTIVE" -eq 0 ]; then
        # Cliente inattivo
        log "Server $SERVER è inattivo"

        if [ ! -f "$STATE_FILE" ]; then
            # Primo giorno di inattività rilevato
            echo "$TODAY" > "$STATE_FILE"
            log "Primo rilevamento inattività per $SERVER, creato file stato"
            # Invia email di primo sollecito
            send_email "$SERVER" "$EMAIL" 0
            echo "$TODAY" > "$LAST_MAIL_FILE"
        else
            START_INACTIVE=$(cat "$STATE_FILE")
            DAYS_INACTIVE=$(( (TODAY - START_INACTIVE) / 86400 ))

            # Invia email se è passato almeno un giorno dall'ultimo invio
            if [ -f "$LAST_MAIL_FILE" ]; then
                LAST_MAIL=$(cat "$LAST_MAIL_FILE")
                DAYS_SINCE_LAST=$(( (TODAY - LAST_MAIL) / 86400 ))
                if [ "$DAYS_SINCE_LAST" -ge 1 ]; then
                    send_email "$SERVER" "$EMAIL" "$DAYS_INACTIVE"
                    echo "$TODAY" > "$LAST_MAIL_FILE"
                else
                    log "Email già inviata oggi per $SERVER, skip"
                fi
            else
                send_email "$SERVER" "$EMAIL" "$DAYS_INACTIVE"
                echo "$TODAY" > "$LAST_MAIL_FILE"
            fi

            # Controlla se superata soglia cancellazione
            if [ "$DAYS_INACTIVE" -ge "$MAX_INACTIVE_DAYS" ]; then
                log "Server $SERVER ha superato $MAX_INACTIVE_DAYS giorni di inattività ($DAYS_INACTIVE)"
                delete_server_data "$SERVER"
            fi
        fi
    else
        # Cliente attivo
        if [ -f "$STATE_FILE" ]; then
            # Era inattivo, ora è tornato attivo
            START_INACTIVE=$(cat "$STATE_FILE")
            DAYS_INACTIVE=$(( (TODAY - START_INACTIVE) / 86400 ))
            log "Server $SERVER è tornato attivo dopo $DAYS_INACTIVE giorni di inattività"
            # Rimuovi file di stato
            rm -f "$STATE_FILE" "$LAST_MAIL_FILE"
        else
            log "Server $SERVER attivo, nessuna azione"
        fi
    fi
done

log "===== Payment Enforcer completato ====="