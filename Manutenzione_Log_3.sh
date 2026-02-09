#!/bin/bash

# Configurazione
ARCHIVE_DIR="archives"
DATE_TAG=$(date +%Y-%m-%d_%H-%M-%S)
MAX_ARCHIVES=5  # Mantiene solo gli ultimi 5 archivi per risparmiare spazio

# Controllo argomenti
if [ -z "$1" ]; then
    echo "Uso: $0 <file_log_da_ruotare> OPPURE <file_archivio_da_estrarre.gz>"
    exit 1
fi

INPUT_FILE="$1"

# --- MODALITÀ ESTRAZIONE (UNZIP) ---
# Controllo se il file termina con .gz
if [[ "$INPUT_FILE" == *.gz ]]; then
    echo "--- Inizio Estrazione per $INPUT_FILE ---"
    
    # 1. Controlla se il file esiste
    if [ ! -f "$INPUT_FILE" ]; then
        echo "Errore: Il file di archivio '$INPUT_FILE' non esiste."
        exit 1
    fi

    # 2. Estrazione
    # Usiamo 'gzip -dk' -> -d (decompress), -k (keep, mantiene il file .gz originale)
    # Se la versione di gzip è molto vecchia e non supporta -k, usa: gzip -d -c "$INPUT_FILE" > "${INPUT_FILE%.gz}"
    gzip -dk "$INPUT_FILE"
    
    if [ $? -eq 0 ]; then
        echo "Successo: File estratto in posizione originale (l'estensione .gz è stata rimossa)."
        echo "Il file compresso è stato mantenuto per sicurezza."
    else
        echo "Errore durante l'estrazione. Assicurati di avere permessi di scrittura o che il file di destinazione non esista già."
        exit 1
    fi

    echo "--- Estrazione completata ---"
    exit 0
fi

# --- MODALITÀ ROTAZIONE (LOG ROTATION) ---
LOG_FILE="$INPUT_FILE"
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
ARCHIVE_NAME="${LOG_BASENAME}_archivio_$(hostname)_$DATE_TAG.log"
echo "Archiviazione di $LOG_FILE in $ARCHIVE_DIR/$ARCHIVE_NAME ..."
cp "$LOG_FILE" "$ARCHIVE_DIR/$ARCHIVE_NAME"

# 4. Svuota il file originale
true > "$LOG_FILE"
echo "File $LOG_FILE svuotato."

# 5. Compressione
gzip "$ARCHIVE_DIR/$ARCHIVE_NAME"
echo "Log compresso: $ARCHIVE_DIR/$ARCHIVE_NAME.gz"

# 6. Pulizia automatica
echo "Pulizia vecchi archivi..."
# Nota: La pulizia agisce solo sui file che corrispondono al pattern del log corrente per evitare di cancellare archivi di altri log
ls -tp "$ARCHIVE_DIR"/${LOG_BASENAME}_archivio_*.log.gz | grep -v '/$' | tail -n +$((MAX_ARCHIVES + 1)) | xargs -I {} rm -- {} 2>/dev/null

echo "--- Manutenzione completata con successo per $LOG_FILE ---"