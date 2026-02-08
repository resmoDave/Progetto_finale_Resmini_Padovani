#!/bin/bash

LOG_FILE="rsync_master.log"
AUDIT_LOG="audit_clean.log"

# Pulizia e Header
touch "$LOG_FILE"
printf "%-20s | %-6s | %-28s | %-12s | %-45s | %s\n" "TIMESTAMP" "PID" "HOST / IP PUBBLICO" "DIMENSIONE" "PERCORSO_RISORSA" "ESITO" > "$AUDIT_LOG"

declare -A PID_MAP
declare -A TRANSFERS

clear
echo "=========================================================================================================================================="
echo "                                       MONITORAGGIO REAL-TIME BACKUP (FULL RESOURCE PATH)"
echo "=========================================================================================================================================="
printf "%-20s | %-6s | %-28s | %-12s | %-45s | %s\n" "TIMESTAMP" "PID" "HOST / IP PUBBLICO" "DIMENSIONE" "PERCORSO_RISORSA" "ESITO"
echo "------------------------------------------------------------------------------------------------------------------------------------------"

log_line() {
    local formatted_line
    # Tronca il percorso se troppo lungo per la tabella (opzionale)
    local path_display=$5
    [ ${#path_display} -gt 44 ] && path_display="...${path_display: -41}"
    
    formatted_line=$(printf "%-20s | %-6s | %-28s | %-12s | %-45s | %s" "$1" "$2" "$3" "$4" "$path_display" "$6")
    echo "$formatted_line"
    echo "$formatted_line" >> "$AUDIT_LOG"
}

tail -n 0 -F "$LOG_FILE" | while read -r line; do
    [ -z "$line" ] && continue

    # 1. Estrazione PID e Timestamp
    PID=$(echo "$line" | grep -oP '(?<=\[)\d+(?=\])')
    [ -z "$PID" ] && continue
    TS=$(echo "$line" | awk '{print $1, $2}')

    # 2. Mapping Host e Nome Host (senza IP)
    # Esempio: 18.236.239.25 (srv-web-04)
    CURRENT_HOST_FULL=$(echo "$line" | grep -oP '\d+\.\d+\.\d+\.\d+ \(srv-[^)]+\)')
    if [ -n "$CURRENT_HOST_FULL" ]; then
        PID_MAP[$PID]="$CURRENT_HOST_FULL"
        # Estraiamo solo il nome host per il percorso (es: srv-web-04)
        HOSTNAME_ONLY=$(echo "$CURRENT_HOST_FULL" | grep -oP '(?<=\()srv-[^)]+')
        PID_HOSTNAME[$PID]=$HOSTNAME_ONLY
    fi
    
    HOST_DISPLAY=${PID_MAP[$PID]:-"Sistema/Interno"}
    HNAME=${PID_HOSTNAME[$PID]:-"unknown"}

    # 3. TRASFERIMENTO IN CORSO (>f)
    if [[ "$line" == *">f"* ]]; then
        FILENAME=$(echo "$line" | awk '{print $(NF-1)}')
        SIZE=$(echo "$line" | awk '{print $NF}')
        
        # Ricostruiamo il percorso completo: host/file
        FULL_RESOURCE_PATH="${HNAME}/${FILENAME}"
        
        TRANSFERS[$PID]="$FULL_RESOURCE_PATH|$SIZE"
        log_line "$TS" "$PID" "$HOST_DISPLAY" "$SIZE" "$FULL_RESOURCE_PATH" "IN_PROGRESS"
        continue
    fi

    # 4. SUCCESSO
    if [[ "$line" == *"received"* && "$line" == *"sent"* ]]; then
        if [ -n "${TRANSFERS[$PID]}" ]; then
            IFS='|' read -r f_path f_size <<< "${TRANSFERS[$PID]}"
            log_line "$TS" "$PID" "$HOST_DISPLAY" "$f_size" "$f_path" "✅ SUCCESS"
            unset TRANSFERS[$PID]
        fi
        continue
    fi

    # 5. ERRORE PERMESSI (Permission Denied)
    if [[ "$line" == *"Permission denied"* ]]; then
        # Estrae il percorso fornito da rsync: /srv-db-03/backup_22.dat
        # Rimuoviamo lo slash iniziale se vogliamo coerenza
        RAW_PATH=$(echo "$line" | grep -oP '(?<=")/?[^"]+(?=")')
        FULL_RESOURCE_PATH=$(echo "$RAW_PATH" | sed 's|^/||')
        
        log_line "$TS" "$PID" "$HOST_DISPLAY" "---" "$FULL_RESOURCE_PATH" "❌ ERROR_PERM"
        unset TRANSFERS[$PID]
        continue
    fi

    # 6. ERRORE CONNESSIONE (Connection Reset)
    if [[ "$line" == *"rsync error:"* ]]; then
        ESITO="❌ ERROR_GENERIC"
        [[ "$line" == *"(code 12)"* ]] && ESITO="❌ ERROR_CONN"
        [[ "$line" == *"(code 23)"* ]] && ESITO="❌ ERROR_PARTIAL"

        if [ -n "${TRANSFERS[$PID]}" ]; then
            IFS='|' read -r f_path f_size <<< "${TRANSFERS[$PID]}"
            log_line "$TS" "$PID" "$HOST_DISPLAY" "$f_size" "$f_path" "$ESITO"
            unset TRANSFERS[$PID]
        else
            log_line "$TS" "$PID" "$HOST_DISPLAY" "---" "${HNAME}/network_fault" "$ESITO"
        fi
        continue
    fi
done