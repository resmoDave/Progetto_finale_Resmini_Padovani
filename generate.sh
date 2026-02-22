#!/bin/bash
# ============================================================================
# generate.sh
# ============================================================================
# DESCRIZIONE:
#   Script di generazione dati di test per il sistema di backup.
#   Crea un ambiente simulato con:
#   - Un daemon rsync locale che simula server remoti
#   - File di backup fittizi con dimensioni variabili
#   - Log rsync realistici con vari scenari (successo, errori, ecc.)
#
# UTILIZZO:
#   ./generate.sh
#
# FUNZIONALITÀ:
#   - Configura e avvia un daemon rsync locale
#   - Genera file di backup casuali per ogni server
#   - Simula trasferimenti rsync con vari esiti
#   - Crea log realistici per testare gli altri script
#
# COMANDI BASH UTILIZZATI:
#   - cat <<EOF: here-document per creare file multi-riga
#   - rsync --daemon: avvia rsync in modalità server
#   - trap: cattura segnali per cleanup all'uscita
#   - dd: genera file con dati casuali
#   - chmod: modifica permessi file
#   - kill -9: termina processi forzatamente
#   - $RANDOM: variabile bash che genera numeri casuali
# ============================================================================

# --- CONFIGURAZIONE ---
# File di log principale di rsync
LOG_FILE="$(pwd)/rsync_master.log"

# Directory che simula lo storage remoto dei client
MOCK_CLIENTS_DIR="$(pwd)/remote_storage"

# Directory dove vengono salvati i backup locali
LOCAL_BACKUP_DIR="$(pwd)/local_backup"

# File di configurazione del daemon rsync
RSYNC_CONF="$(pwd)/rsyncd.conf"

# Porta su cui ascolta il daemon rsync
PORT=9876

# Numero di iterazioni (trasferimenti da simulare)
ITERAZIONI=100

# --- PULIZIA INIZIALE ---
# rm -rf: rimozione ricorsiva e forzata
# Rimuove eventuali dati da esecuzioni precedenti
rm -rf "$MOCK_CLIENTS_DIR" "$LOCAL_BACKUP_DIR" "$LOG_FILE" "$RSYNC_CONF"

# Crea le directory necessarie
# -p: crea directory genitori se necessari
mkdir -p "$MOCK_CLIENTS_DIR" "$LOCAL_BACKUP_DIR"

# --- 1. CREAZIONE CONFIGURAZIONE RSYNC DAEMON ---
# Il daemon rsync permette di simulare "pull" da localhost come se fosse remoto
# cat <<EOF: here-document - tutto ciò che segue fino a EOF viene scritto nel file
# Le variabili $PORT e $MOCK_CLIENTS_DIR vengono espanse
cat <<EOF > "$RSYNC_CONF"
port = $PORT
use chroot = no
[clients]
    path = $MOCK_CLIENTS_DIR
    read only = yes
    list = yes
EOF

# --- 2. AVVIO DEL DAEMON RSYNC ---
# rsync --daemon: avvia rsync in modalità server (ascolta connessioni)
# --config: specifica il file di configurazione
# --address: bind su localhost solo (sicurezza)
rsync --daemon --config="$RSYNC_CONF" --address=127.0.0.1

# trap: comando per gestire segnali e uscita
# "comando" EXIT: esegue il comando quando lo script termina
# fuser -k $PORT/tcp: uccide il processo che usa la porta
# Questo assicura che il daemon venga fermato anche se lo script fallisce
trap "fuser -k $PORT/tcp; rm $RSYNC_CONF" EXIT

# --- 3. MAPPATURA SERVER/IP ---
# Array dei server da simulare
ALL_CLIENTS=("srv-web-01" "srv-web-02" "srv-web-03" "srv-web-04" "srv-web-05" "srv-db-01" "srv-db-02" "srv-db-03")

# declare -A: dichiara array associativo (chiave-valore)
declare -A HOST_IPS

# Genera IP casuali per ogni server
# $RANDOM: variabile bash che genera numeri casuali (0-32767)
# $((RANDOM%256)): modulo per ottenere valori 0-255
for s in "${ALL_CLIENTS[@]}"; do
    HOST_IPS[$s]="$((RANDOM%256)).$((RANDOM%256)).$((RANDOM%256)).$((RANDOM%256))"
done

echo "--- GENERATING AUTHENTIC PULL LOGS (DAEMON MODE) ---"

# --- 4. CICLO PRINCIPALE DI GENERAZIONE ---
# for ((i=1; i<=N; i++)): ciclo con sintassi C-like
for ((i=1; i<=$ITERAZIONI; i++)); do
    # Seleziona un client casuale
    # $((RANDOM%8)): numero casuale da 0 a 7
    CLIENT=${ALL_CLIENTS[$((RANDOM%8))]}
    IP=${HOST_IPS[$CLIENT]}
    
    # Dimensione file diversa per web server (piccoli) e db server (grandi)
    # [[ ]]: test esteso con pattern matching
    # srv-web*: matcha qualsiasi stringa che inizia con "srv-web"
    [[ $CLIENT == srv-web* ]] && SIZE=$((RANDOM%5 + 1)) || SIZE=$((RANDOM%40 + 20))

    # Crea il file sul lato "remoto" (nel mock storage)
    mkdir -p "$MOCK_CLIENTS_DIR/$CLIENT"
    FILE="backup_$i.dat"
    
    # dd: comando per copiare dati
    # if=/dev/urandom: input da generatore casuale
    # of=...: output file
    # bs=1M: block size = 1 megabyte
    # count=$SIZE: numero di blocchi
    # 2>/dev/null: nasconde le statistiche di dd
    dd if=/dev/urandom of="$MOCK_CLIENTS_DIR/$CLIENT/$FILE" bs=1M count=$SIZE 2>/dev/null

    # FORMATTAZIONE LOG RSYNC
    # %i: itemize changes - mostra il tipo di trasferimento
    # %f: filename
    # %l: literal length (dimensione)
    # Questo formato produce log simili a quelli reali
    LOG_FMT="$IP ($CLIENT) %i %f %l"

    # --- SIMULAZIONE SCENARI ---
    # Genera uno scenario casuale (0-9)
    SCENARIO=$((RANDOM%10))
    
    case $SCENARIO in
        0) # --- ERRORE DI PERMESSI ---
            # chmod 000: rimuove tutti i permessi
            chmod 000 "$MOCK_CLIENTS_DIR/$CLIENT/$FILE"
            
            # rsync -av: archive mode + verbose
            # --log-file: specifica il file di log
            # rsync://...: URL per connettersi al daemon
            rsync -av --log-file="$LOG_FILE" --log-file-format="$LOG_FMT" \
                rsync://127.0.0.1:$PORT/clients/$CLIENT/ "$LOCAL_BACKUP_DIR/$CLIENT/" 2>/dev/null
            
            # Ripristina permessi per usi futuri
            chmod 644 "$MOCK_CLIENTS_DIR/$CLIENT/$FILE"
            ;;
        1) # --- ERRORE DI CONNESSIONE ---
            # Avvia rsync in background (&)
            rsync -av --log-file="$LOG_FILE" --log-file-format="$LOG_FMT" \
                rsync://127.0.0.1:$PORT/clients/$CLIENT/ "$LOCAL_BACKUP_DIR/$CLIENT/" &
            
            # $!: variabile che contiene il PID dell'ultimo processo background
            RPID=$!
            
            # Breve pausa per far partire il trasferimento
            sleep 0.01
            
            # kill -9: invia SIGKILL (terminazione immediata)
            kill -9 $RPID 2>/dev/null
            
            # Scrive manualmente un messaggio di errore nel log
            echo "$(date +'%Y/%m/%d %H:%M:%S') [$RPID] $IP ($CLIENT) rsync error: connection reset by peer (code 12)" >> "$LOG_FILE"
            ;;
        *) # --- TRASFERIMENTO SUCCESSO ---
            # La maggior parte degli scenari (8 su 10) sono successi
            rsync -av --log-file="$LOG_FILE" --log-file-format="$LOG_FMT" \
                rsync://127.0.0.1:$PORT/clients/$CLIENT/ "$LOCAL_BACKUP_DIR/$CLIENT/" > /dev/null
            ;;
    esac

    # Progress indicator ogni 20 iterazioni
    # $((i % 20)): modulo - resto della divisione
    [ $((i % 20)) -eq 0 ] && echo "Pulling $i/100 completed..."
done

# --- REPORT FINALE ---
echo "------------------------------------------------"
echo "✅ DONE. Check the log: $LOG_FILE"
echo "Example of a successful pull line from your log:"
# tail -n 1: mostra l'ultima riga del file
tail -n 1 "$LOG_FILE"