#!/bin/bash

# ==============================================================================
# SCRIPT 02: Smart Backup con Retry Queue e Resume automatico
# DESCRIZIONE: Esegue un backup rsync. Se fallisce, mette il job in "attesa",
#              controlla la connettività e riprova fino al successo o al limite tentativi.
# ==============================================================================

# CONFIGURAZIONE
MAX_RETRIES=5               # Numero massimo di tentativi
RETRY_DELAY=10              # Secondi di attesa tra un tentativo e l'altro
LOG_FILE="./backup_retry.log"
QUEUE_FILE="./active_retry_queue.txt" # File che simula la "Coda di Retry"

# Parametri da riga di comando
SOURCE_DIR="$1"
DEST_DIR="$2"

# Funzione per mostrare l'uso
usage() {
    echo "Uso: $0 <cartella_sorgente> <destinazione>"
    echo "Esempio: $0 ./data /tmp/backup_dest"
    echo "Esempio Remote: $0 ./data user@192.168.1.50:/var/backups/"
    exit 1
}

# Controllo parametri
if [ -z "$SOURCE_DIR" ] || [ -z "$DEST_DIR" ]; then
    usage
fi

# Funzione di logging
log_msg() {
    local TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$TIMESTAMP] $1" | tee -a "$LOG_FILE"
}

# Inizio procedura
log_msg "START: Avvio backup di $SOURCE_DIR verso $DEST_DIR"

attempt=1
success=0

while [ $attempt -le $MAX_RETRIES ]; do
    
    log_msg "Tentativo $attempt di $MAX_RETRIES in corso..."
    
    # ESECUZIONE RSYNC
    # -a: archive mode (mantiene permessi, date, ecc)
    # -v: verbose
    # -z: compressione dati
    # --partial: CRUCIALE -> Se cade la linea, mantiene il file parziale 
    #            e al prossimo giro riprende da lì invece di ricominciare da zero.
    # --append-verify: Ottimizza il resume dei file parziali
    
    rsync -avz --partial --append-verify "$SOURCE_DIR" "$DEST_DIR" >> "$LOG_FILE" 2>&1

    # Controllo Exit Code di rsync ($? è 0 se tutto ok, diverso da 0 se errore)
    if [ $? -eq 0 ]; then
        success=1
        break # Esce dal ciclo while
    else
        log_msg "ERRORE: Trasferimento fallito o interrotto."
        
        # Aggiungo alla "Coda di Retry" (simulazione)
        echo "$(date) - JOB FAILED: $SOURCE_DIR -> $DEST_DIR (Attempt $attempt)" >> "$QUEUE_FILE"
        
        log_msg "WARN: Inserito in coda di retry. Attesa $RETRY_DELAY secondi..."
        sleep $RETRY_DELAY
        
        # Incrementa contatore
        ((attempt++))
    fi
done

# Gestione esito finale
if [ $success -eq 1 ]; then
    log_msg "SUCCESS: Backup completato correttamente."
    # Rimuove il job dalla coda se presente (pulizia)
    sed -i "\#$SOURCE_DIR -> $DEST_DIR#d" "$QUEUE_FILE" 2>/dev/null
    exit 0
else
    log_msg "FATAL: Numero massimo di tentativi raggiunto. Backup NON completato."
    echo "ATTENZIONE: Il backup richiede intervento manuale." >> "$QUEUE_FILE"
    exit 1
fi