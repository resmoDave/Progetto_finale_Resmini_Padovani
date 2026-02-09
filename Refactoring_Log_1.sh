#!/bin/bash

LOG_FILE="rsync_master.log"

# ==============================================================================
# 1. RICONOSCIMENTO AUTOMATICO COLONNE
# ==============================================================================

# Definiamo array per salvare la configurazione scelta dall'utente
declare -a SELECTED_COLS_TYPE   # Che tipo di dato (TS, PID, HOST, SIZE, PATH, RES)
declare -a SELECTED_COLS_WIDTH  # Larghezza colonna
declare -a SELECTED_COLS_HEADER # Il nome che hai passato tu

AUDIT_LOG="audit_clean.log"

# Funzione per aggiungere una colonna alla configurazione
add_col() {
    SELECTED_COLS_TYPE+=("$1")
    SELECTED_COLS_WIDTH+=("$2")
    SELECTED_COLS_HEADER+=("$3")
}

# SE NON PASSI ARGOMENTI: Carica configurazione default
if [ "$#" -eq 0 ]; then
    add_col "TS"   20 "TIMESTAMP"
    add_col "PID"  6  "PID"
    add_col "HOST" 28 "HOST / IP PUBBLICO"
    add_col "SIZE" 12 "DIMENSIONE"
    add_col "PATH" 45 "PERCORSO_RISORSA"
    add_col "RES"  15 "ESITO"

# SE PASSI ARGOMENTI: Analizza ogni argomento per capire cosa vuoi
else
    AUDIT_LOG="audit_custom.log"
    echo ">>> Rilevati argomenti personalizzati. Configurazione output su: $AUDIT_LOG"

    for arg in "$@"; do
        # Convertiamo in minuscolo per il confronto
        lower_arg=$(echo "$arg" | tr '[:upper:]' '[:lower:]')

        case "$lower_arg" in
            *date*|*time*|*data*|*ora*|*timestamp*)
                add_col "TS" 20 "$arg"
                ;;
            *pid*|*proc*|*id*)
                add_col "PID" 6 "$arg"
                ;;
            *ip*|*host*|*server*|*sorgente*|*source*)
                add_col "HOST" 28 "$arg"
                ;;
            *byte*|*dim*|*size*|*kb*|*weight*)
                add_col "SIZE" 12 "$arg"
                ;;
            *file*|*path*|*percorso*|*name*|*nome*)
                add_col "PATH" 45 "$arg"
                ;;
            *status*|*esito*|*result*|*stato*)
                add_col "RES" 15 "$arg"
                ;;
            *)
                # Se scrivi qualcosa che non capisco, lo ignoro o lo mappo come testo generico?
                # Per sicurezza, se non riconosco, presumo sia un campo "PATH" o "INFO"
                echo "!!! Attenzione: Argomento '$arg' non riconosciuto. Lo salto."
                ;;
        esac
    done
fi

# ==============================================================================
# 2. COSTRUZIONE HEADER E FORMATO
# ==============================================================================

# Costruiamo la stringa dell'Header e il Separatore dinamicamente
HEADER_STR=""
FORMAT_STR=""

for i in "${!SELECTED_COLS_HEADER[@]}"; do
    width="${SELECTED_COLS_WIDTH[$i]}"
    name="${SELECTED_COLS_HEADER[$i]}"
    
    # Costruiamo pezzo per printf (es: "%-20s | ")
    FORMAT_STR="${FORMAT_STR}%-${width}s | "
    
    # Costruiamo pezzo header
    HEADER_PART=$(printf "%-${width}s | " "$name")
    HEADER_STR="${HEADER_STR}${HEADER_PART}"
done

# Pulizia finale (rimuovi l'ultimo " | ")
FORMAT_STR="${FORMAT_STR% | }"
HEADER_STR="${HEADER_STR% | }"
SEPARATOR_STR=$(printf '%*s' "${#HEADER_STR}" '' | tr ' ' '-')

# Inizializza File Log
touch "$LOG_FILE"
echo "$HEADER_STR" > "$AUDIT_LOG"

declare -A PID_MAP
declare -A PID_HOSTNAME
declare -A TRANSFERS

# ==============================================================================
# 3. INTERFACCIA
# ==============================================================================
clear
echo "======================================================================================================================"
echo "                                 MONITORAGGIO REAL-TIME (LOG: $AUDIT_LOG)"
echo "======================================================================================================================"
echo "$SEPARATOR_STR"
echo "$HEADER_STR"
echo "$SEPARATOR_STR"

# ==============================================================================
# 4. FUNZIONE LOGGING DINAMICO
# ==============================================================================

log_line() {
    # Riceviamo i dati grezzi standard
    local raw_ts="$1"
    local raw_pid="$2"
    local raw_host="$3"
    local raw_size="$4"
    local raw_path="$5"
    local raw_res="$6"

    # Tronca path se troppo lungo
    [ ${#raw_path} -gt 44 ] && raw_path="...${raw_path: -41}"

    # Costruiamo l'array dei dati da stampare BASATO SULL'ORDINE SCELTO DALL'UTENTE
    local print_args=()
    
    for type in "${SELECTED_COLS_TYPE[@]}"; do
        case "$type" in
            "TS")   print_args+=("$raw_ts") ;;
            "PID")  print_args+=("$raw_pid") ;;
            "HOST") print_args+=("$raw_host") ;;
            "SIZE") print_args+=("$raw_size") ;;
            "PATH") print_args+=("$raw_path") ;;
            "RES")  print_args+=("$raw_res") ;;
        esac
    done

    # Stampa
    local out_line=$(printf "$FORMAT_STR" "${print_args[@]}")
    echo "$out_line"
    echo "$out_line" >> "$AUDIT_LOG"
}

# ==============================================================================
# 5. LOOP PRINCIPALE
# ==============================================================================

tail -n 0 -F "$LOG_FILE" | while read -r line; do
    [ -z "$line" ] && continue

    # Estrazione Dati
    PID=$(echo "$line" | grep -oP '(?<=\[)\d+(?=\])')
    [ -z "$PID" ] && continue
    TS=$(echo "$line" | awk '{print $1, $2}')

    # Host Mapping
    CURRENT_HOST_FULL=$(echo "$line" | grep -oP '\d+\.\d+\.\d+\.\d+ \(srv-[^)]+\)')
    if [ -n "$CURRENT_HOST_FULL" ]; then
        PID_MAP[$PID]="$CURRENT_HOST_FULL"
        HOSTNAME_ONLY=$(echo "$CURRENT_HOST_FULL" | grep -oP '(?<=\()srv-[^)]+')
        PID_HOSTNAME[$PID]=$HOSTNAME_ONLY
    fi
    HOST_DISPLAY=${PID_MAP[$PID]:-"Sistema/Interno"}
    HNAME=${PID_HOSTNAME[$PID]:-"unknown"}

    # LOGICA 1: In Progress
    if [[ "$line" == *">f"* ]]; then
        FILENAME=$(echo "$line" | awk '{print $(NF-1)}')
        SIZE=$(echo "$line" | awk '{print $NF}')
        FULL_PATH="${HNAME}/${FILENAME}"
        TRANSFERS[$PID]="$FULL_PATH|$SIZE"
        
        log_line "$TS" "$PID" "$HOST_DISPLAY" "$SIZE" "$FULL_PATH" "IN_PROGRESS"
        continue
    fi

    # LOGICA 2: Successo
    if [[ "$line" == *"received"* && "$line" == *"sent"* ]]; then
        if [ -n "${TRANSFERS[$PID]}" ]; then
            IFS='|' read -r f_path f_size <<< "${TRANSFERS[$PID]}"
            log_line "$TS" "$PID" "$HOST_DISPLAY" "$f_size" "$f_path" "✅ SUCCESS"
            unset TRANSFERS[$PID]
        fi
        continue
    fi

    # LOGICA 3: Errore Permessi
    if [[ "$line" == *"Permission denied"* ]]; then
        RAW=$(echo "$line" | grep -oP '(?<=")/?[^"]+(?=")')
        FULL_PATH=$(echo "$RAW" | sed 's|^/||')
        log_line "$TS" "$PID" "$HOST_DISPLAY" "---" "$FULL_PATH" "❌ ERROR_PERM"
        unset TRANSFERS[$PID]
        continue
    fi

    # LOGICA 4: Errori Vari
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