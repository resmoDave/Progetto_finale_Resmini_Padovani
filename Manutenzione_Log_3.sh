#!/bin/bash

# Configurazione
LOG_FILE="backup.log"
ARCHIVE_DIR="archives"
DATE_TAG=$(date +%Y-%m-%d_%H-%M-%S)
MAX_ARCHIVES=5  # Mantiene solo gli ultimi 5 archivi per risparmiare spazio

echo "--- Inizio Manutenzione Log ---"

# 1. Controlla se il file di log esiste ed è più grande di 0
if [ ! -s "$LOG_FILE" ]; then
    echo "Il file di log è vuoto o non esiste. Nessuna rotazione necessaria."
    exit 0
fi

# 2. Crea la cartella di archivio se non esiste
mkdir -p "$ARCHIVE_DIR"

# 3. Rotazione: Sposta il log attuale in un file temporaneo con timestamp
# Usiamo 'cp' e poi svuotiamo il file originale per non interrompere rsync o altri processi
echo "Archiviazione di $LOG_FILE..."
cp "$LOG_FILE" "$ARCHIVE_DIR/backup_$DATE_TAG.log"

# 4. Svuota il file originale (fondamentale per non saturare il disco)
# Invece di cancellarlo, lo azzeriamo. Così i processi che scrivono non crashano.
true > "$LOG_FILE"
echo "File $LOG_FILE svuotato."

# 5. Compressione: Riduciamo drasticamente lo spazio occupato (fino al 90%)
gzip "$ARCHIVE_DIR/backup_$DATE_TAG.log"
echo "Log compresso: $ARCHIVE_DIR/backup_$DATE_TAG.log.gz"

# 6. Pulizia automatica: Elimina i log più vecchi di MAX_ARCHIVES
echo "Pulizia vecchi archivi..."
ls -tp "$ARCHIVE_DIR"/backup_*.log.gz | grep -v '/$' | tail -n +$((MAX_ARCHIVES + 1)) | xargs -I {} rm -- {} 2>/dev/null

echo "--- Manutenzione completata con successo ---" 