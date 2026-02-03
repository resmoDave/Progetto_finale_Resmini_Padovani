#!/bin/bash

LOG_FILE="rsync_master.log"
AUDIT_LOG="audit_clean.log" # File di output pulito

# --- FIX: CREAZIONE FORZATA DEI FILE SE MANCANO ---
touch "$LOG_FILE"
touch "$AUDIT_LOG"

# Creiamo un database temporaneo in memoria per i PID
declare -A PID_MAP

# Pulizia schermo e Header a video
clear
echo "===================================================================================================================="
echo "                                MONITORAGGIO REAL-TIME BACKUP AZIENDALE (RESOURCE FOCUS)"
echo "===================================================================================================================="
printf "%-20s | %-6s | %-28s | %-12s | %-40s | %s\n" "TIMESTAMP" "PID" "HOST / IP PUBBLICO" "DIMENSIONE" "PERCORSO_FILE" "ESITO"
echo "--------------------------------------------------------------------------------------------------------------------"

# Header nel file di log pulito (se il file è vuoto)
if [ ! -s "$AUDIT_LOG" ]; then
    printf "%-20s | %-6s | %-28s | %-12s | %-40s | %s\n" "TIMESTAMP" "PID" "HOST / IP PUBBLICO" "DIMENSIONE" "PERCORSO_FILE" "ESITO" > "$AUDIT_LOG"
fi

# Leggiamo il log grezzo e processiamo
tail -n 0 -F "$LOG_FILE" | while read -r line; do
    
    # Ignora le righe vuote
    [ -z "$line" ] && continue

    # 1. ESTRAZIONE PID
    PID=$(echo "$line" | grep -oP '\[\K[0-9]+(?=\])')
    [ -z "$PID" ] && continue 

    # 2. ESTRAZIONE TIMESTAMP
    TS=$(echo "$line" | awk '{print $1, $2}')

    # 3. IDENTIFICAZIONE HOST/IP
    CURRENT_HOST=$(echo "$line" | grep -oP '\d+\.\d+\.\d+\.\d+ \(srv-[^)]+\)')
    
    if [ -n "$CURRENT_HOST" ]; then
        PID_MAP[$PID]="$CURRENT_HOST"
    else
        CURRENT_HOST=${PID_MAP[$PID]}
    fi

    [ -z "$CURRENT_HOST" ] && CURRENT_HOST="Sistema/Interno"

    # 4. ANALISI ESITO E RISORSA
    ESITO="SUCCESS"
    SIZE="0"
    FILE_PATH="---" # Nuovo campo

    if [[ "$line" == *"rsync error:"* ]] || [[ "$line" == *"Permission denied"* ]]; then
        # CASO ERRORE: Estraiamo il percorso dal messaggio di errore di rsync
        if [[ "$line" == *"(code 12)"* ]]; then ESITO="❌ ERROR_CONN";
        elif [[ "$line" == *"(code 11)"* ]]; then ESITO="❌ ERROR_SPACE";
        elif [[ "$line" == *"(code 23)"* ]] || [[ "$line" == *"Permission denied"* ]]; then ESITO="❌ ERROR_PERM";
        else ESITO="❌ ERROR_GENERIC"; fi
        
        # Tentativo di estrarre il percorso dal messaggio di errore (se presente)
        FILE_PATH=$(echo "$line" | grep -oP 'source_chaos/[^":\s]+')
        [ -z "$FILE_PATH" ] && FILE_PATH="ANOMALIA_CONNESSIONE"
        SIZE="---"

    elif [[ "$line" == *">f"* ]]; then
        # CASO SUCCESSO: Estraiamo nome file e dimensione
        ESITO="✅ SUCCESS"
        
        # Estraiamo il nome file. Rsync lo logga dopo l'azione (%f)
        FILE_RAW=$(echo "$line" | awk '{for(i=7;i<=NF;i++) if($i ~ /\//) print $i}')
        # Rimuoviamo il percorso del server Rsync e lasciamo il percorso relativo al client
        FILE_PATH=$(echo "$FILE_RAW" | grep -oP 'source_chaos/\K.*')
        
        # Estraiamo la dimensione (sempre l'ultimo campo della riga di trasferimento)
        SIZE=$(echo "$line" | awk '{print $NF}')
    else
        continue
    fi

    # 5. CREAZIONE DELLA RIGA FORMATTATA
    FORMATTED_LINE=$(printf "%-20s | %-6s | %-28s | %-12s | %-40s | %s" \
                      "$TS" "$PID" "$CURRENT_HOST" "$SIZE" "$FILE_PATH" "$ESITO")

    # 6. OUTPUT SU ENTRAMBE LE DESTINAZIONI
    echo "$FORMATTED_LINE"           # Stampa a video
    echo "$FORMATTED_LINE" >> "$AUDIT_LOG" # Salva nel file pulito

done