#!/bin/bash
# ============================================================================
# Warn_Client_2.sh
# ============================================================================
# DESCRIZIONE:
#   Questo script monitora il file di log di audit (audit_clean.log) per
#   rilevare errori di connessione (ERROR_CONN) o errori di permessi (ERROR_PERM).
#   Quando rileva un errore, recupera l'email del contatto tramite API REST
#   e invia una notifica via email.
#
# UTILIZZO:
#   ./Warn_Client_2.sh
#
# ARCHITETTURA:
#   - Un processo in background monitora il log file
#   - Un worker in foreground processa la coda delle email da inviare
#   - Comunicazione tramite file coda (.warn_client_queue)
#
# COMANDI BASH UTILIZZATI:
#   - export: esporta variabili d'ambiente per i processi figli
#   - grep -v: filtra le righe che NON matchano il pattern
#   - xargs: converte l'output in argomenti per export
#   - curl -s: esegue richieste HTTP in modalità silent
#   - mail: comando Unix per inviare email
#   - sed -i: modifica file in-place
#   - BASH_REMATCH: array contenente i match delle regex con =~
# ============================================================================

# 1. CARICAMENTO VARIABILI DAL FILE .env
# -f: verifica se il file esiste ed è regolare
# grep -v '^#': rimuove le righe che iniziano con # (commenti)
# xargs: converte le righe in argomenti per il comando export
# Questo permette di caricare configurazioni sensibili (password, API key) da un file esterno
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# CONFIGURAZIONE
LOG_FILE="audit_clean.log"                    # File di log da monitorare
SERVER_API_URL="http://127.0.0.1:8000/get-email/"  # Endpoint API per recuperare email
TARGET_ID="srv-web-01"                        # ID del server da monitorare (modificabile)

# Messaggi di avvio
echo "--- [START] Script di monitoraggio avviato ---"
echo "Log file: $LOG_FILE"
echo "Target ID: $TARGET_ID"
echo "API Server: $SERVER_API_URL"
echo "----------------------------------------------"

# Funzione per aggiungere un evento alla coda delle email
# Argomenti: $1=server_id, $2=error_type, $3=file_path, $4=timestamp
# >>: append - aggiunge in fondo al file senza sovrascrivere
send_email_to_queue() {
    echo "[DEBUG] Aggiunta alla coda: ID=$1, Errore=$2"
    # Formato: server_id|error_type|file_path|timestamp
    echo "$1|$2|$3|$4" >> .warn_client_queue
}

# Worker che processa la coda delle email
# Questo è un loop infinito che controlla periodicamente la coda
process_queue() {
    # while true: loop infinito (daemon)
    while true; do
        # -s: verifica se il file esiste E ha dimensione > 0
        # !: negazione logica
        if [ ! -s .warn_client_queue ]; then
            # sleep: mette in pausa lo script per N secondi
            # Riduce il carico CPU quando la coda è vuota
            sleep 1
            continue  # Salta all'iterazione successiva
        fi

        # Legge la prima riga dalla coda
        # IFS='|': Imposta il separatore di campo per dividere la riga
        # read -r: legge una riga senza interpretare i backslash
        # <: redirezione input dal file
        IFS='|' read -r server_id error_type file_path timestamp < .warn_client_queue
        
        # sed -i '1d': elimina la prima riga del file in-place
        # -i: modifica il file direttamente (in-place)
        # 1d: comando delete sulla riga 1
        sed -i '1d' .warn_client_queue

        echo "[PROCESS] Analizzo evento per: $server_id"

        # --- FILTRO ID ---
        # Verifica se l'evento riguarda il server target configurato
        # !=: operatore di disuguaglianza stringa
        if [[ "$server_id" != "$TARGET_ID" ]]; then
            echo "[SKIP] Ignoro $server_id perché non è il target ($TARGET_ID)"
            continue
        fi

        # RECUPERO EMAIL TRAMITE API REST
        echo "[API] Richiesta email per $server_id..."
        # curl -s: esegue richiesta HTTP in modalità silent (senza progress bar)
        # grep -oP: estrae solo la parte che matcha il pattern Perl
        # Pattern '"email":\s*"\K[^\"]+':
        #   "email":\s*": matcha "email" seguito da opzionali spazi e virgolette
        #   \K: reset del match (esclude tutto ciò che precede dal risultato)
        #   [^\"]+: uno o più caratteri che non sono virgolette
        recipient_email=$(curl -s "${SERVER_API_URL}${server_id}" | grep -oP '"email":\s*"\K[^\"]+')
        
        # Verifica che l'email sia stata trovata
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

        # INVIO EMAIL
        # mail -s: comando Unix per inviare email
        # -s: specifica l'oggetto (subject)
        # Il corpo viene passato tramite pipe (|)
        echo "$EMAIL_BODY" | mail -s "$EMAIL_SUBJECT" "$recipient_email"
        
        # $?: variabile speciale che contiene l'exit code dell'ultimo comando
        # -eq 0: significa che il comando ha avuto successo
        if [ $? -eq 0 ]; then
            echo "[SUCCESS] Email inviata con successo a $recipient_email"
        else
            echo "[ERROR] Errore durante l'invio con il comando mail"
        fi

    done
}

# --- MONITORAGGIO LOG ---
# Variabile per tracciare quante righe sono già state processate
# Serve per riprendere il monitoraggio dal punto corretto dopo un riavvio
processed_lines=0

# Se esiste il file di offset, legge il valore salvato
# &&: esecuzione condizionale - esegue il comando a destra solo se quello a sinistra ha successo
# cat: legge e stampa il contenuto del file
[ -f .warn_client_offset ] && processed_lines=$(cat .warn_client_offset)

# Regex per estrarre il contenuto tra parentesi tonde
# \( e \): parentesi letterali (escape)
# ([^)]+): gruppo di cattura - uno o più caratteri che non sono parentesi chiusa
# I gruppi di cattura vengono salvati in BASH_REMATCH
REGEX_PAREN="\(([^)]+)\)"

# Calcola la riga di partenza per tail
# $(( )): aritmetica bash - esegue operazioni matematiche
start_line=$((processed_lines + 1))

echo "[MONITOR] Inizio scansione log dalla riga $start_line..."

# MONITORAGGIO CONTINUO DEL LOG
# tail -F -n +N:
#   -F: follow - segue il file anche se viene ruotato/ricreato
#   -n +N: inizia dalla riga N (non dall'inizio del file)
# | while read -r line: pipe che passa ogni riga al loop
# &: esegue l'intero comando in background (diventa un processo separato)
tail -F -n +$start_line "$LOG_FILE" | while read -r line; do
    # (( )): aritmetica bash - incrementa il contatore
    ((processed_lines++))
    # Salva il progresso per poter riprendere dopo un riavvio
    echo "$processed_lines" > .warn_client_offset
    
    # Rilevamento errori
    # ||: operatore OR logico - vero se almeno una condizione è vera
    # *ERROR_CONN*: pattern matching - qualsiasi riga contenente "ERROR_CONN"
    if [[ "$line" == *"ERROR_CONN"* ]] || [[ "$line" == *"ERROR_PERM"* ]]; then
        echo "[FOUND] Rilevato errore nel log: $line"
        
        # Parsing della riga di log
        # La riga ha formato: timestamp|pid|host|dimension|file_path|error_type
        # <<<: here-string - passa la stringa come input a read
        IFS='|' read -r timestamp pid host_field dimension file_path error_type <<< "$line"
        
        # xargs senza argomenti: rimuove spazi iniziali/finali (trim)
        # Utile per pulire i campi estratti
        timestamp=$(echo "$timestamp" | xargs)
        host_field=$(echo "$host_field" | xargs)
        file_path=$(echo "$file_path" | xargs)
        error_type=$(echo "$error_type" | xargs)

        # Estrazione del server_id
        # =~: operatore di regex matching in bash
        # Se matcha, i gruppi di cattura sono in BASH_REMATCH
        # BASH_REMATCH[0]: match completo
        # BASH_REMATCH[1]: primo gruppo di cattura (contenuto tra parentesi)
        if [[ "$host_field" =~ $REGEX_PAREN ]]; then
            server_id="${BASH_REMATCH[1]}"
        else
            # Fallback: estrae il primo componente del percorso file
            # cut -d'/' -f1: divide per '/' e prende il primo campo
            server_id=$(echo "$file_path" | cut -d'/' -f1)
            # Gestione caso speciale per directory "source_chaos"
            [[ "$server_id" == "source_chaos" ]] && server_id=$(echo "$file_path" | cut -d'/' -f2)
        fi
        
        # Aggiunge l'evento alla coda per il worker
        send_email_to_queue "$server_id" "$error_type" "$file_path" "$timestamp"
    fi
done &  # & alla fine: esegue il loop in background

# Avvia il worker in primo piano (foreground)
# Questo mantiene lo script attivo e visibile nel terminale
process_queue