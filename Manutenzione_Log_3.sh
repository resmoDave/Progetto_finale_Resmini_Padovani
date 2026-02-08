#!/bin/bash


# Configurazione
ARCHIVE_DIR="archives"
DATE_TAG=$(date +%Y-%m-%d_%H-%M-%S)
MAX_ARCHIVES=5  # Mantiene solo gli ultimi 5 archivi per risparmiare spazio

# Controllo argomenti
if [ -z "$1" ]; then
    echo "Uso: $0 <file_log_da_ruotare>"
    exit 1
fi

LOG_FILE="$1"
LOG_BASENAME=$(basename "$LOG_FILE" .log)

echo "--- Inizio Manutenzione Log per $LOG_FILE ---"

# 1. Controlla se il file di log esiste ed è più grande di 0
if [ ! -s "$LOG_FILE" ]; then
    echo "Il file di log è vuoto o non esiste. Nessuna rotazione necessaria."
    exit 0
fi

# 2. Crea la cartella di archivio se non esiste
mkdir -p "$ARCHIVE_DIR"


# 3. Rotazione: Sposta il log attuale in un file temporaneo con timestamp e info aggiuntive
# Usiamo 'cp' e poi svuotiamo il file originale per non interrompere rsync o altri processi
ARCHIVE_NAME="${LOG_BASENAME}_archivio_$(hostname)_$DATE_TAG.log"
echo "Archiviazione di $LOG_FILE in $ARCHIVE_DIR/$ARCHIVE_NAME ..."
cp "$LOG_FILE" "$ARCHIVE_DIR/$ARCHIVE_NAME"

# 4. Svuota il file originale (fondamentale per non saturare il disco)
# Invece di cancellarlo, lo azzeriamo. Così i processi che scrivono non crashano.
true > "$LOG_FILE"
echo "File $LOG_FILE svuotato."

# 5. Compressione: Riduciamo drasticamente lo spazio occupato (fino al 90%)
gzip "$ARCHIVE_DIR/$ARCHIVE_NAME"
echo "Log compresso: $ARCHIVE_DIR/$ARCHIVE_NAME.gz"

# 6. Pulizia automatica: Elimina i log più vecchi di MAX_ARCHIVES
echo "Pulizia vecchi archivi..."
ls -tp "$ARCHIVE_DIR"/${LOG_BASENAME}_archivio_*.log.gz | grep -v '/$' | tail -n +$((MAX_ARCHIVES + 1)) | xargs -I {} rm -- {} 2>/dev/null

echo "--- Manutenzione completata con successo per $LOG_FILE ---"