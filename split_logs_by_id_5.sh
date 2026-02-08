#!/bin/bash
# Script: split_logs_by_id.sh
# Uso: ./split_logs_by_id.sh <ID_CLIENTE> <DATA_INIZIO> <DATA_FINE> <FILE_LOG>
# Esempio: ./split_logs_by_id.sh srv-db-01 "2026/02/01" "2026/02/08" audit_clean.log

if [ "$#" -ne 4 ]; then
    echo "Uso: $0 <ID_CLIENTE> <DATA_INIZIO> <DATA_FINE> <FILE_LOG>"
    exit 1
fi

ID_CLIENTE="$1"
DATA_INIZIO="$2"
DATA_FINE="$3"
FILE_LOG="$4"

# Output file
OUT_FILE="${ID_CLIENTE}_estratto.log"


# Converte le date in formato YYYYMMDD per confronto
DATA_INIZIO_FMT=$(echo "$DATA_INIZIO" | tr -d "/")
DATA_FINE_FMT=$(echo "$DATA_FINE" | tr -d "/")

# Estrai solo righe che contengono l'ID e sono nel range di date
awk -v id="$ID_CLIENTE" -v di="$DATA_INIZIO_FMT" -v df="$DATA_FINE_FMT" '
    BEGIN { FS="[|]"; OFS="|" }
    NR==1 { next } # salta header
    {
        # Rimuovi spazi
        gsub(/^ +| +$/, "", $1); gsub(/^ +| +$/, "", $5);
        # Prendi solo righe con id nel percorso risorsa
        if (index($5, id) > 0) {
            data = $1; gsub("/", "", data); gsub(/ .*/, "", data);
            if (data >= di && data <= df) print $0;
        }
    }
' "$FILE_LOG" > "$OUT_FILE"

echo "Log estratto per $ID_CLIENTE dal $DATA_INIZIO al $DATA_FINE in $OUT_FILE"
