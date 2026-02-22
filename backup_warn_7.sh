#!/bin/bash
# ============================================================================
# backup_warn_7.sh
# ============================================================================
# DESCRIZIONE:
#   Script di monitoraggio backup che verifica l'età degli ultimi backup
#   per ogni server configurato. Se un backup supera la soglia di giorni
#   configurata, invia un'email di allerta al contatto associato.
#
# UTILIZZO:
#   ./backup_warn_7.sh
#
# FUNZIONALITÀ:
#   - Verifica l'età dell'ultimo backup per ogni server
#   - Recupera l'email del contatto tramite API REST
#   - Invia alert via email se il backup è troppo vecchio o mancante
#
# COMANDI BASH UTILIZZATI:
#   - command -v: verifica se un comando è disponibile nel sistema
#   - curl -s: esegue richieste HTTP in modalità silent
#   - jq: parser JSON da riga di comando
#   - find -printf: formatta l'output di find
#   - stat -c %Y: ottiene timestamp di modifica in formato Unix
#   - tee -a: scrive su stdout e append su file
#   - mail: comando Unix per inviare email
# ============================================================================

# Caricamento variabili d'ambiente dal file .env (opzionale)
# Il file .env può contenere configurazioni sensibili come API key
if [ -f .env ]; then
    # grep -v '^#': rimuove le righe commentate
    # xargs: converte le righe in argomenti per export
    export $(grep -v '^#' .env | xargs)
fi

# -------------------- CONFIGURAZIONE --------------------
# $(pwd): restituisce la directory di lavoro corrente
LOCAL_BACKUP_DIR="$(pwd)/local_backup"      # Directory principale dei backup

# Configurazione API
API_BASE_URL="http://127.0.0.1:8000"        # Endpoint base del server API Python
API_GET_EMAIL="$API_BASE_URL/get-email"     # Endpoint per ottenere email

# Parametri di soglia
MAX_AGE_DAYS=7                               # Giorni massimi per considerare un backup recente
LOG_FILE="backup_check.log"                  # File di log delle operazioni

# Lista completa dei server da monitorare
# Array bash con gli ID dei server
ALL_CLIENTS=(
    "srv-web-01" "srv-web-02" "srv-web-03" "srv-web-04" "srv-web-05"
    "srv-db-01"  "srv-db-02"  "srv-db-03"
)

# -------------------- FUNZIONI --------------------

# Funzione di logging con timestamp
# tee -a: scrive sia su stdout che su file (append mode)
# -a: append, non sovrascrive
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Recupera l'email associata a un server chiamando l'API REST
# Argomenti: $1 = server_id
# Restituisce: l'email o stringa vuota in caso di errore
get_email_for_server() {
    local server_id="$1"
    local url="${API_GET_EMAIL}/${server_id}"
    local email=""

    # command -v: verifica se un comando esiste nel sistema
    # &>/dev/null: redirige sia stdout che stderr a /dev/null
    if command -v jq &>/dev/null; then
        # jq -r '.email': estrae il campo email dal JSON
        # -r: raw output (senza virgolette)
        # --max-time 5: timeout di 5 secondi per la richiesta
        email=$(curl -s --max-time 5 "$url" | jq -r '.email' 2>/dev/null)
        # Verifica se jq ha restituito "null" (campo non trovato)
        [[ "$email" == "null" ]] && email=""
    else
        # Fallback senza jq: usa grep con regex Perl-compatible
        # grep -oP: estrae solo la parte che matcha il pattern
        # '"email":\s*"\K[^"]+': 
        #   "email":\s*": matcha il campo email
        #   \K: reset del match (esclude dal risultato)
        #   [^"]+: il valore dell'email
        email=$(curl -s --max-time 5 "$url" | grep -oP '"email":\s*"\K[^"]+')
    fi

    echo "$email"
}

# Invia un'email di allerta tramite il comando mail
# Argomenti: $1=server_id, $2=last_backup, $3=age_days, $4=recipient_email
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

    # Invia email usando il comando mail
    # -s: subject (oggetto)
    # Il corpo viene passato tramite pipe
    echo "$body" | mail -s "$subject" "$recipient_email"
    
    # Verifica successo dell'invio
    # $?: exit code dell'ultimo comando
    if [ $? -eq 0 ]; then
        log "Mail inviata con successo a $recipient_email per $server_id"
    else
        log "ERRORE: Invio mail fallito per $server_id (destinatario: $recipient_email)"
    fi
}

# -------------------- CONTROLLO PRINCIPALE --------------------
log "===== Avvio controllo backup ====="

# Itera su tutti i server configurati
for SERVER in "${ALL_CLIENTS[@]}"; do
    log "Controllo server: $SERVER"

    # 1. RECUPERO EMAIL DESTINATARIO
    EMAIL=$(get_email_for_server "$SERVER")
    if [ -z "$EMAIL" ]; then
        log "ERRORE: Impossibile ottenere email per $SERVER (API non raggiungibile o server non trovato). Skippo."
        continue  # Passa al prossimo server
    fi
    log "Email destinatario: $EMAIL"

    # 2. TROVA IL BACKUP PIÙ RECENTE
    BACKUP_DIR="${LOCAL_BACKUP_DIR}/${SERVER}"
    
    # Verifica esistenza directory
    if [ ! -d "$BACKUP_DIR" ]; then
        log "WARN: Directory $BACKUP_DIR non esiste. Nessun backup presente."
        last_file="NESSUN BACKUP"
        age_days="N/A"
    else
        # find con -printf per ottenere timestamp e percorso
        # -maxdepth 1: non scende nelle sottodirectory
        # -type f: cerca solo file (non directory)
        # -printf '%T@ %p\n': stampa timestamp Unix (@) e percorso
        # sort -n: ordina numericamente
        # tail -1: prende l'ultimo (più recente)
        # cut -d' ' -f2-: rimuove il timestamp, mantiene il percorso
        last_file=$(find "$BACKUP_DIR" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
        
        if [ -z "$last_file" ]; then
            log "WARN: Nessun file di backup trovato in $BACKUP_DIR"
            last_file="NESSUN BACKUP"
            age_days="N/A"
        else
            # Calcolo età del backup
            # stat -c %Y: ottiene modification time in formato Unix timestamp
            last_mtime=$(stat -c %Y "$last_file")
            current_time=$(date +%s)
            # Differenza in secondi, poi convertita in giorni
            age_seconds=$((current_time - last_mtime))
            age_days=$((age_seconds / 86400))  # 86400 = secondi in un giorno
            log "Ultimo backup: $last_file (modificato $age_days giorni fa)"
        fi
    fi

    # 3. VERIFICA SOGLIA E INVIO ALERT
    # =: confronto stringa esatto (per "NESSUN BACKUP")
    # -gt: greater than (confronto numerico)
    if [ "$last_file" = "NESSUN BACKUP" ] || [ "$age_days" -gt "$MAX_AGE_DAYS" ]; then
        log "ALLERTA: Backup per $SERVER non recente (età: $age_days giorni). Invio mail..."
        send_alert "$SERVER" "$last_file" "$age_days" "$EMAIL"
    else
        log "OK: Backup per $SERVER recente (età: $age_days giorni). Nessuna azione."
    fi
done

log "===== Controllo completato ====="