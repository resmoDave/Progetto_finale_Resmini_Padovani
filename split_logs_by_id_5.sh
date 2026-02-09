#!/bin/bash

# File log fisso
FILE_LOG="audit_clean.log"

if [ ! -f "$FILE_LOG" ]; then
    echo "Errore: Il file '$FILE_LOG' non è presente."
    exit 1
fi

if [ "$#" -ne 3 ] && [ "$#" -ne 1 ]; then
    echo "Uso: $0 <ID_CLIENTE> [<DATA_INIZIO> <DATA_FINE>]"
    exit 1
fi

ID_CLIENTE="$1"

if [ "$#" -eq 3 ]; then
    # Converte le date in formato YYYYMMDD rimuovendo gli slash
    DATA_INIZIO_FMT=$(echo "$2" | tr -d "/")
    DATA_FINE_FMT=$(echo "$3" | tr -d "/")
    MSG="Log estratto per $ID_CLIENTE dal $2 al $3"
else
    DATA_INIZIO_FMT="00000000"
    DATA_FINE_FMT="99999999"
    MSG="Log estratto per $ID_CLIENTE (Tutto lo storico)"
fi

OUT_FILE="${ID_CLIENTE}_estratto.log"

awk -v id="$ID_CLIENTE" -v di="$DATA_INIZIO_FMT" -v df="$DATA_FINE_FMT" '
    BEGIN { FS="|"; OFS="|" }
    {
        # 1. Rimuovi eventuali ritorni a capo di Windows (\r)
        gsub(/\r/, "", $0);

        # 2. Pulisce la colonna 1 (Data) e colonna 5 (Percorso) da spazi bianchi
        cmd_trim = "gsub(/^[ \t]+|[ \t]+$/, \"\", ";
        eval_trim1 = cmd_trim "$1)"; 
        eval_trim5 = cmd_trim "$5)";
        
        # Eseguiamo pulizia manuale semplificata per compatibilità
        gsub(/^[ \t]+|[ \t]+$/, "", $1);
        gsub(/^[ \t]+|[ \t]+$/, "", $5);

        # 3. Estrai la data in formato YYYYMMDD per il confronto
        # Prende i primi 10 caratteri (YYYY/MM/DD) e toglie gli /
        split($1, a, " "); 
        data_pulita = a[1];
        gsub(/\//, "", data_pulita);

        # 4. Logica di filtraggio
        # Controlla se l id è nel percorso (colonna 5) E se la data è nel range
        if (index($5, id) > 0) {
            if (data_pulita >= di && data_pulita <= df) {
                print $0;
            }
        }
    }
' "$FILE_LOG" > "$OUT_FILE"

echo "$MSG in file: $OUT_FILE"