#!/bin/bash
# ============================================================================
# payment_enforcer_9.sh
# ============================================================================
# DESCRIZIONE:
#   Script per la gestione degli insoluti (clienti non paganti).
#   Monitora lo stato di pagamento dei server e:
#   - Invia email di sollecito giornaliere ai clienti inattivi
#   - Cancella i dati dei clienti dopo un periodo configurabile di insoluto
#   - Traccia lo stato di inattività in file appositi
#
# UTILIZZO:
#   ./payment_enforcer_9.sh
#
# FUNZIONALITÀ:
#   - Verifica stato attivo tramite API REST
#   - Tracciamento giorni di inattività
#   - Invio automatico solleciti email
#   - Cancellazione dati dopo soglia configurabile
#   - Reset automatico se il cliente torna attivo
#
# COMANDI BASH UTILIZZATI:
#   - mkdir -p: crea directory ricorsivamente
#   - curl -s: richieste HTTP silent
#   - jq: parser JSON
#   - mail: invio email
#   - rm -rf: rimozione ricorsiva forzata
#   - cat: lettura file
#   - date +%s: timestamp Unix
# ============================================================================

# -------------------- CONFIGURAZIONE --------------------
# URL base dell'API per verificare stato server
API_BASE_URL="http://127.0.0.1:8000"

# Directory dei backup locali
LOCAL_BACKUP_DIR="$(pwd)/local_backup"

# Directory per tracciare lo stato di inattività
# Contiene file che registrano quando l'inattività è iniziata
INACTIVE_STATE_DIR="$(pwd)/inactive_state"

# File di log delle operazioni
LOG_FILE="payment_enforcer.log"

# Soglia di giorni prima della cancellazione dati
MAX_INACTIVE_DAYS=30

# Prefisso per l'oggetto delle email di sollecito
EMAIL_SUBJECT_PREFIX="[SOLLECITO PAGAMENTO]"

# Crea la directory di stato se non esiste
# -p: crea directory genitori se necessari, non errore se esiste già
mkdir -p "$INACTIVE_STATE_DIR"

# -------------------- FUNZIONI --------------------

# Funzione di logging con timestamp
# tee -a: scrive su stdout e append su file
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Recupera lo stato e l'email di un server dall'API
# Argomenti: $1 = server_id
# Restituisce: "active|email" o "ERROR" in caso di problema
get_server_status() {
    local server_id="$1"
    local url="${API_BASE_URL}/get-email/${server_id}"
    local active=""
    local email=""

    # Esegue la richiesta HTTP
    # --max-time 5: timeout di 5 secondi
    response=$(curl -s --max-time 5 "$url")
    
    # Verifica successo della richiesta
    # $? -ne 0: exit code diverso da zero (errore)
    # -z: stringa vuota
    if [ $? -ne 0 ] || [ -z "$response" ]; then
        log "ERRORE: API non raggiungibile per $server_id"
        echo "ERROR"
        return
    fi

    # Parsing della risposta JSON
    if command -v jq &>/dev/null; then
        # Usa jq se disponibile (più affidabile)
        active=$(echo "$response" | jq -r '.active' 2>/dev/null)
        email=$(echo "$response" | jq -r '.email' 2>/dev/null)
    else
        # Fallback con grep
        active=$(echo "$response" | grep -oP '"active":\s*\K[0-9]+')
        email=$(echo "$response" | grep -oP '"email":\s*"\K[^"]+')
    fi

    # Verifica che entrambi i campi siano presenti
    if [[ -z "$active" || -z "$email" ]]; then
        log "ERRORE: Risposta API malformata per $server_id"
        echo "ERROR"
        return
    fi

    # Restituisce i valori separati da pipe
    echo "$active|$email"
}

# Invia email di sollecito al cliente
# Argomenti: $1=server_id, $2=email, $3=days_inactive
# Restituisce: 0 se successo, 1 se errore
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

    # Invia email usando il comando mail
    echo "$body" | mail -s "$subject" "$email"
    
    if [ $? -eq 0 ]; then
        log "Email inviata a $email per $server_id (insoluto da $days_inactive giorni)"
        return 0
    else
        log "ERRORE: Invio email fallito per $server_id"
        return 1
    fi
}

# Cancella i dati di un server (usato dopo soglia di insoluto)
# Argomenti: $1 = server_id
delete_server_data() {
    local server_id="$1"
    local backup_path="$LOCAL_BACKUP_DIR/$server_id"
    
    # Verifica che la directory esista
    if [ -d "$backup_path" ]; then
        log "CANCELLAZIONE dati per $server_id (insoluto superato $MAX_INACTIVE_DAYS giorni)"
        
        # rm -rf: rimozione ricorsiva e forzata
        # -r: recursive (include sottodirectory)
        # -f: force (non chiede conferma, ignora file inesistenti)
        # NOTA: Per cancellazione sicura si potrebbe usare shred
        rm -rf "$backup_path"
        
        if [ $? -eq 0 ]; then
            log "Dati cancellati con successo per $server_id"
            # Rimuove anche i file di stato di inattività
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

# Lista dei server da monitorare
# Potrebbe essere ottenuta dinamicamente dall'API /all-emails
ALL_SERVERS=("srv-web-01" "srv-web-02" "srv-web-03" "srv-web-04" "srv-web-05" "srv-db-01" "srv-db-02" "srv-db-03")

# Itera su tutti i server configurati
for SERVER in "${ALL_SERVERS[@]}"; do
    log "Processo server: $SERVER"

    # Recupera stato ed email
    STATUS=$(get_server_status "$SERVER")
    if [ "$STATUS" = "ERROR" ]; then
        continue  # Passa al prossimo server
    fi

    # Estrae i campi dalla risposta "active|email"
    # cut -d'|' -f1: divide per | e prende il primo campo
    ACTIVE=$(echo "$STATUS" | cut -d'|' -f1)
    EMAIL=$(echo "$STATUS" | cut -d'|' -f2)

    # Definisce i file di stato per questo server
    STATE_FILE="$INACTIVE_STATE_DIR/${SERVER}.start"      # Data inizio inattività
    LAST_MAIL_FILE="$INACTIVE_STATE_DIR/${SERVER}.lastmail" # Data ultimo invio email
    
    # Timestamp corrente in secondi Unix
    TODAY=$(date +%s)

    if [ "$ACTIVE" -eq 0 ]; then
        # --- CLIENTE INATTIVO (non pagante) ---
        log "Server $SERVER è inattivo"

        if [ ! -f "$STATE_FILE" ]; then
            # Primo rilevamento di inattività
            # Crea il file con il timestamp di oggi
            echo "$TODAY" > "$STATE_FILE"
            log "Primo rilevamento inattività per $SERVER, creato file stato"
            
            # Invia prima email di sollecito
            send_email "$SERVER" "$EMAIL" 0
            echo "$TODAY" > "$LAST_MAIL_FILE"
        else
            # Inattività già tracciata, calcola giorni passati
            # cat: legge il contenuto del file
            START_INACTIVE=$(cat "$STATE_FILE")
            
            # Calcolo giorni di inattività
            # $(( )): aritmetica bash
            # 86400: secondi in un giorno
            DAYS_INACTIVE=$(( (TODAY - START_INACTIVE) / 86400 ))

            # Invia email se è passato almeno un giorno dall'ultimo invio
            if [ -f "$LAST_MAIL_FILE" ]; then
                LAST_MAIL=$(cat "$LAST_MAIL_FILE")
                DAYS_SINCE_LAST=$(( (TODAY - LAST_MAIL) / 86400 ))
                
                # -ge 1: almeno un giorno passato
                if [ "$DAYS_SINCE_LAST" -ge 1 ]; then
                    send_email "$SERVER" "$EMAIL" "$DAYS_INACTIVE"
                    echo "$TODAY" > "$LAST_MAIL_FILE"
                else
                    log "Email già inviata oggi per $SERVER, skip"
                fi
            else
                # File lastmail mancante, invia comunque
                send_email "$SERVER" "$EMAIL" "$DAYS_INACTIVE"
                echo "$TODAY" > "$LAST_MAIL_FILE"
            fi

            # Verifica se superata la soglia per cancellazione
            if [ "$DAYS_INACTIVE" -ge "$MAX_INACTIVE_DAYS" ]; then
                log "Server $SERVER ha superato $MAX_INACTIVE_DAYS giorni di inattività ($DAYS_INACTIVE)"
                delete_server_data "$SERVER"
            fi
        fi
    else
        # --- CLIENTE ATTIVO (in regola) ---
        if [ -f "$STATE_FILE" ]; then
            # Era inattivo, ora è tornato attivo
            START_INACTIVE=$(cat "$STATE_FILE")
            DAYS_INACTIVE=$(( (TODAY - START_INACTIVE) / 86400 ))
            log "Server $SERVER è tornato attivo dopo $DAYS_INACTIVE giorni di inattività"
            
            # Rimuove i file di stato (reset)
            rm -f "$STATE_FILE" "$LAST_MAIL_FILE"
        else
            log "Server $SERVER attivo, nessuna azione"
        fi
    fi
done

log "===== Payment Enforcer completato ====="