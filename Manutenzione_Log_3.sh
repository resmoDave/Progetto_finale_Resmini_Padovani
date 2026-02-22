#!/bin/bash
# ============================================================================
# Manutenzione_Log_3.sh
# ============================================================================
# DESCRIZIONE:
#   Script per la gestione automatica della rotazione dei file di log.
#   Supporta due modalità operative:
#   1. ROTAZIONE: comprime e archivia un file di log attivo
#   2. ESTRAZIONE: decomprime un archivio .gz precedentemente creato
#
# UTILIZZO:
#   Rotazione: ./Manutenzione_Log_3.sh <file_log>
#   Estrazione: ./Manutenzione_Log_3.sh <file_archivio.gz>
#
# FUNZIONALITÀ:
#   - Crea archivi compressi con gzip
#   - Mantiene solo gli ultimi N archivi (configurabile)
#   - Aggiunge timestamp e hostname al nome del file archiviato
#
# COMANDI BASH UTILIZZATI:
#   - date: formatta data/ora corrente
#   - basename: estrae il nome del file senza percorso
#   - hostname: restituisce il nome dell'host
#   - gzip: comprime/decomprime file
#   - mkdir -p: crea directory ricorsivamente
#   - ls -t: lista file ordinati per data di modifica (più recenti prima)
#   - tail -n +N: mostra le righe dalla N-esima in poi
#   - xargs -I {}: esegue comandi con placeholder
# ============================================================================

# CONFIGURAZIONE
# Directory dove salvare gli archivi compressi
ARCHIVE_DIR="archives"

# Genera un timestamp per il nome del file
# date +%Y-%m-%d_%H-%M-%S: formato data personalizzato
#   %Y: anno a 4 cifre (es: 2024)
#   %m: mese a 2 cifre (01-12)
#   %d: giorno a 2 cifre (01-31)
#   %H: ora in formato 24h (00-23)
#   %M: minuti (00-59)
#   %S: secondi (00-59)
DATE_TAG=$(date +%Y-%m-%d_%H-%M-%S)

# Numero massimo di archivi da mantenere
# Gli archivi più vecchi vengono eliminati automaticamente
MAX_ARCHIVES=5

# CONTROLLO ARGOMENTI
# $1: primo argomento passato allo script
# -z: verifica se la stringa è vuota
# $0: nome dello script stesso
if [ -z "$1" ]; then
    echo "Uso: $0 <file_log_da_ruotare> OPPURE <file_archivio_da_estrarre.gz>"
    exit 1  # Exit code 1 indica errore
fi

INPUT_FILE="$1"

# --- MODALITÀ ESTRAZIONE (UNZIP) ---
# Verifica se l'input è un file compresso
# *.gz: pattern matching per verificare l'estensione
if [[ "$INPUT_FILE" == *.gz ]]; then
    echo "--- Inizio Estrazione per $INPUT_FILE ---"
    
    # 1. Verifica esistenza del file
    # ! -f: negazione del test "file exists and is regular"
    if [ ! -f "$INPUT_FILE" ]; then
        echo "Errore: Il file di archivio '$INPUT_FILE' non esiste."
        exit 1
    fi

    # 2. Estrazione con gzip
    # gzip -dk:
    #   -d: decomprimi (decompress mode)
    #   -k: mantieni il file originale (keep)
    # Senza -k, gzip eliminerebbe il file .gz dopo la decompressione
    gzip -dk "$INPUT_FILE"
    
    # Verifica successo dell'operazione
    # $?: exit code dell'ultimo comando eseguito
    # -eq 0: significa successo (zero errors)
    if [ $? -eq 0 ]; then
        echo "Successo: File estratto in posizione originale (l'estensione .gz è stata rimossa)."
        echo "Il file compresso è stato mantenuto per sicurezza."
    else
        echo "Errore durante l'estrazione. Assicurati di avere permessi di scrittura o che il file di destinazione non esista già."
        exit 1
    fi

    echo "--- Estrazione completata ---"
    exit 0  # Exit code 0 indica successo
fi

# --- MODALITÀ ROTAZIONE (LOG ROTATION) ---
LOG_FILE="$INPUT_FILE"

# basename: estrae il nome del file senza il percorso
# basename "path/to/file.log" .log -> restituisce "file"
# Il secondo argomento rimuove l'estensione specificata
LOG_BASENAME=$(basename "$LOG_FILE" .log)

echo "--- Inizio Manutenzione Log per $LOG_FILE ---"

# 1. Verifica che il file di log esista e abbia contenuto
# -s: verifica se il file esiste E ha dimensione > 0 (non vuoto)
if [ ! -s "$LOG_FILE" ]; then
    echo "Il file di log è vuoto o non esiste. Nessuna rotazione necessaria."
    exit 0  # Non è un errore, semplicemente non c'è nulla da fare
fi

# 2. Crea la directory di archivio se non esiste
# mkdir -p: crea directory genitori se necessari, non errore se esiste già
# -p: "parents" - crea tutto il path gerarchico
mkdir -p "$ARCHIVE_DIR"

# 3. Copia il log nella directory di archivio con nome univoco
# hostname: restituisce il nome dell'host corrente
# Utile per identificare la provenienza dell'archivio in ambienti multi-server
ARCHIVE_NAME="${LOG_BASENAME}_archivio_$(hostname)_$DATE_TAG.log"
echo "Archiviazione di $LOG_FILE in $ARCHIVE_DIR/$ARCHIVE_NAME ..."

# cp: copia il file preservando l'originale
cp "$LOG_FILE" "$ARCHIVE_DIR/$ARCHIVE_NAME"

# 4. Svuota il file di log originale
# true > file: comando "true" (sempre successo) con output rediretto
# Questo svuota il file senza eliminarlo, preservando permessi e inode
# Alternativa: echo "" > "$LOG_FILE" o : > "$LOG_FILE"
true > "$LOG_FILE"
echo "File $LOG_FILE svuotato."

# 5. Compressione dell'archivio
# gzip: comprime il file aggiungendo estensione .gz
# Il file originale viene sostituito dalla versione compressa
gzip "$ARCHIVE_DIR/$ARCHIVE_NAME"
echo "Log compresso: $ARCHIVE_DIR/$ARCHIVE_NAME.gz"

# 6. PULIZIA AUTOMATICA VECCHI ARCHIVI
echo "Pulizia vecchi archivi..."

# Pipeline complessa per eliminare gli archivi più vecchi:
#
# ls -tp: lista file ordinati per tempo (più recenti prima)
#   -t: ordina per modification time (più recenti prima)
#   -p: aggiunge '/' alle directory per identificarle
#
# grep -v '/$': rimuove le directory dalla lista
#   -v: inverte il match (seleziona righe che NON matchano)
#   '/$': pattern che matcha righe che terminano con /
#
# tail -n +N: mostra righe dalla N-esima in poi
#   $((MAX_ARCHIVES + 1)): aritmetica bash, es: 5+1=6
#   Quindi mostra dalla riga 6 in poi (i file più vecchi)
#
# xargs -I {}: esegue il comando per ogni riga
#   -I {}: usa {} come placeholder per l'argomento
#   rm -- {}: elimina il file (-- previene problemi con nomi che iniziano con -)
#
# 2>/dev/null: redirige stderr a /dev/null (nasconde errori)
ls -tp "$ARCHIVE_DIR"/${LOG_BASENAME}_archivio_*.log.gz | grep -v '/$' | tail -n +$((MAX_ARCHIVES + 1)) | xargs -I {} rm -- {} 2>/dev/null

echo "--- Manutenzione completata con successo per $LOG_FILE ---"