#!/bin/bash
# ============================================================================
# Refactoring_Log_1.sh
# ============================================================================
# DESCRIZIONE:
#   Questo script monitora in tempo reale il file di log di rsync (rsync_master.log)
#   e formatta le informazioni in modo leggibile, mostrando lo stato dei trasferimenti
#   file tra server. Supporta configurazione personalizzata delle colonne da visualizzare.
#
# UTILIZZO:
#   ./Refactoring_Log_1.sh [colonna1] [colonna2] ...
#   Esempio: ./Refactoring_Log_1.sh "Data" "PID" "File" "Stato"
#
# COMANDI BASH UTILIZZATI:
#   - declare -a: dichiara un array indicizzato (numerico)
#   - declare -A: dichiara un array associativo (chiave-valore)
#   - ${!array[@]}: espande gli indici dell'array
#   - ${#var}: restituisce la lunghezza della variabile
#   - ${var:start:length}: estrae una sottostringa
#   - ${var%pattern}: rimuove il pattern dalla fine (shortest match)
#   - ${var:-default}: usa default se var è vuoto
#   - [ condition ] && command: esecuzione condizionale (short-circuit)
#   - IFS='|': Internal Field Separator per split di stringhe
# ============================================================================

# File di log da monitorare (input)
LOG_FILE="rsync_master.log"

# ==============================================================================
# 1. RICONOSCIMENTO AUTOMATICO COLONNE
# ==============================================================================
# Questa sezione permette di configurare dinamicamente quali colonne mostrare
# nell'output. Se non vengono passati argomenti, usa una configurazione default.

# Dichiarazione di array indicizzati per la configurazione delle colonne
# declare -a: crea un array indicizzato (accesso tramite indice numerico 0,1,2...)
declare -a SELECTED_COLS_TYPE   # Tipo di dato: TS (timestamp), PID, HOST, SIZE, PATH, RES
declare -a SELECTED_COLS_WIDTH  # Larghezza in caratteri per ogni colonna
declare -a SELECTED_COLS_HEADER # Intestazione visualizzata per ogni colonna

# File di output dove salvare il log formattato
AUDIT_LOG="audit_clean.log"

# Funzione per aggiungere una colonna alla configurazione
# Argomenti: $1=tipo, $2=larghezza, $3=intestazione
# Uso di += per appendere elementi agli array
add_col() {
    SELECTED_COLS_TYPE+=("$1")   # Aggiunge il tipo all'array dei tipi
    SELECTED_COLS_WIDTH+=("$2")  # Aggiunge la larghezza all'array delle larghezze
    SELECTED_COLS_HEADER+=("$3") # Aggiunge l'intestazione all'array delle intestazioni
}

# SE NON PASSI ARGOMENTI: Carica configurazione default
# $#: variabile speciale che contiene il numero di argomenti passati allo script
# -eq: operatore di confronto numerico "uguale a"
if [ "$#" -eq 0 ]; then
    # Configurazione di default con tutte le colonne predefinite
    add_col "TS"   20 "TIMESTAMP"      # Colonna timestamp, larghezza 20 caratteri
    add_col "PID"  6  "PID"            # Process ID, larghezza 6 caratteri
    add_col "HOST" 28 "HOST / IP PUBBLICO"  # Hostname/IP, larghezza 28 caratteri
    add_col "SIZE" 12 "DIMENSIONE"     # Dimensione file, larghezza 12 caratteri
    add_col "PATH" 45 "PERCORSO_RISORSA"     # Percorso file, larghezza 45 caratteri
    add_col "RES"  15 "ESITO"          # Risultato operazione, larghezza 15 caratteri

# SE PASSI ARGOMENTI: Analizza ogni argomento per capire cosa vuoi
else
    # Cambia il file di output quando si usano argomenti personalizzati
    AUDIT_LOG="audit_custom.log"
    echo ">>> Rilevati argomenti personalizzati. Configurazione output su: $AUDIT_LOG"

    # "$@": espande tutti gli argomenti passati allo script come lista separata
    for arg in "$@"; do
        # tr '[:upper:]' '[:lower:]': converte tutti i caratteri maiuscoli in minuscoli
        # [:upper:] e [:lower:] sono classi di caratteri POSIX
        # Questo permette il case-insensitive matching
        lower_arg=$(echo "$arg" | tr '[:upper:]' '[:lower:]')

        # case: costrutto di controllo simile a switch in altri linguaggi
        # I pattern con * sono wildcard (es: *date* matcha qualsiasi stringa contenente "date")
        # |: operatore OR per matchare pattern multipli
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
                # Pattern default: se nessun altro pattern matcha
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
# Questa sezione costruisce dinamicamente l'intestazione della tabella e la
# stringa di formato per printf, basandosi sulle colonne selezionate.

# Inizializzazione stringhe vuote per accumulare il contenuto
HEADER_STR=""   # Conterrà l'intestazione formattata
FORMAT_STR=""   # Conterrà il formato per printf (es: "%-20s | %-6s | ...")

# Ciclo sugli indici degli array
# ${!array[@]}: espande gli INDICI dell'array, non i valori
# Utile quando devi accedere a più array paralleli allo stesso indice
for i in "${!SELECTED_COLS_HEADER[@]}"; do
    width="${SELECTED_COLS_WIDTH[$i]}"   # Estrae la larghezza per questa colonna
    name="${SELECTED_COLS_HEADER[$i]}"   # Estrae il nome intestazione
    
    # Costruzione della stringa di formato per printf
    # %-${width}s: formato per stringa allineata a sinistra (-) con larghezza specificata
    # Esempio: se width=20, diventa "%-20s | "
    FORMAT_STR="${FORMAT_STR}%-${width}s | "
    
    # Costruzione dell'header formattato
    # printf "%-20s | " "NOME": stampa "NOME" allineato a sinistra in 20 caratteri
    HEADER_PART=$(printf "%-${width}s | " "$name")
    HEADER_STR="${HEADER_STR}${HEADER_PART}"
done

# Pulizia finale (rimuovi l'ultimo " | ")
# ${var%pattern}: rimuove il pattern più corto dalla FINE della variabile
# Esempio: "a | b | c | " diventa "a | b | c"
FORMAT_STR="${FORMAT_STR% | }"
HEADER_STR="${HEADER_STR% | }"

# Creazione della linea separatrice
# printf '%*s' N '': stampa N spazi (usando il modificatore * per la larghezza dinamica)
# ${#HEADER_STR}: restituisce la lunghezza della stringa HEADER_STR
# tr ' ' '-': sostituisce tutti gli spazi con trattini
SEPARATOR_STR=$(printf '%*s' "${#HEADER_STR}" '' | tr ' ' '-')

# Inizializza File Log
# touch: crea il file se non esiste, o aggiorna il timestamp se esiste già
touch "$LOG_FILE"
# >: redirezione output che sovrascrive il file (crea nuovo file vuoto)
echo "$HEADER_STR" > "$AUDIT_LOG"

# Dichiarazione di array associativi (chiave-valore)
# declare -A: crea un array associativo dove gli indici sono stringhe invece che numeri
# Questi array servono per tracciare le informazioni dei processi rsync
declare -A PID_MAP        # Mappa PID -> "IP (hostname)" per identificare la sorgente
declare -A PID_HOSTNAME   # Mappa PID -> solo hostname (es: srv-backup01)
declare -A TRANSFERS      # Mappa PID -> "percorso|dimensione" per tracciare trasferimenti in corso

# ==============================================================================
# 3. INTERFACCIA
# ==============================================================================
# Visualizzazione dell'interfaccia utente iniziale

# clear: pulisce lo schermo del terminale
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
# Questa funzione formatta e stampa una riga di log secondo la configurazione
# delle colonne scelta dall'utente.

log_line() {
    # Dichiarazione variabili locali
    # local: limita lo scope della variabile alla funzione corrente
    # $1, $2, ...: parametri posizionali passati alla funzione
    local raw_ts="$1"      # Timestamp grezzo
    local raw_pid="$2"     # Process ID
    local raw_host="$3"    # Host/IP sorgente
    local raw_size="$4"    # Dimensione file
    local raw_path="$5"    # Percorso file
    local raw_res="$6"     # Risultato/Esito

    # Tronca path se troppo lungo
    # ${#var}: restituisce la lunghezza della stringa
    # -gt: operatore di confronto "greater than" (maggiore di)
    # &&: esecuzione condizionale - esegue il comando a destra solo se quello a sinistra ha successo
    # ${var: -N}: estrae gli ultimi N caratteri dalla stringa (notare lo spazio prima del -)
    [ ${#raw_path} -gt 44 ] && raw_path="...${raw_path: -41}"

    # Costruiamo l'array dei dati da stampare BASATO SULL'ORDINE SCELTO DALL'UTENTE
    # Array locale per accumulare i valori nell'ordine corretto
    local print_args=()
    
    # Itera sui tipi di colonna selezionati e aggiunge il valore corrispondente
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

    # Stampa formattata
    # printf con array: "${print_args[@]}" espande l'array come argomenti separati
    local out_line=$(printf "$FORMAT_STR" "${print_args[@]}")
    echo "$out_line"                           # Stampa a video
    echo "$out_line" >> "$AUDIT_LOG"           # >>: append al file (non sovrascrive)
}

# ==============================================================================
# 5. LOOP PRINCIPALE
# ==============================================================================
# Questo è il cuore dello script: legge continuamente il file di log e processa
# ogni nuova riga che viene aggiunta.

# tail -n 0 -F: 
#   -n 0: inizia dalla fine del file (non mostra righe esistenti)
#   -F: segue il file anche se viene ruotato/ricreato (follow + retry)
# |: pipe - redirige l'output del comando a sinistra all'input del comando a destra
# while read -r line: legge riga per riga
#   -r: non interpreta i backslash come caratteri di escape
tail -n 0 -F "$LOG_FILE" | while read -r line; do
    # Salta righe vuote
    # -z: restituisce vero se la stringa è vuota (zero length)
    [ -z "$line" ] && continue

    # ESTRRAZIONE DATI CON REGEX
    # grep -oP: estrae solo la parte che matcha il pattern Perl
    # Pattern '(?<=\[)\d+(?=\])': 
    #   (?<=\[): lookbehind positivo - deve essere preceduto da [
    #   \d+: una o più cifre
    #   (?=\]): lookahead positivo - deve essere seguito da ]
    # Esempio: "[12345]" estrae "12345"
    PID=$(echo "$line" | grep -oP '(?<=\[)\d+(?=\])')
    [ -z "$PID" ] && continue
    
    # awk '{print $1, $2}': stampa il primo e secondo campo separati da spazio
    # awk divide automaticamente la riga in campi basandosi su whitespace
    # $1 = primo campo, $2 = secondo campo, ecc.
    TS=$(echo "$line" | awk '{print $1, $2}')

    # HOST MAPPING: estrae IP e hostname dalla riga di log
    # Pattern '\d+\.\d+\.\d+\.\d+': matcha un indirizzo IP (4 gruppi di cifre separati da .)
    # \(srv-[^)]+\): matcha "(srv-qualsiasi)" dove [^)]+ significa "uno o più caratteri che non sono )"
    CURRENT_HOST_FULL=$(echo "$line" | grep -oP '\d+\.\d+\.\d+\.\d+ \(srv-[^)]+\)')
    
    # -n: restituisce vero se la stringa NON è vuota (non-zero length)
    if [ -n "$CURRENT_HOST_FULL" ]; then
        # Salva la mappatura PID -> Host completo nell'array associativo
        PID_MAP[$PID]="$CURRENT_HOST_FULL"
        # Estrae solo l'hostname usando lookbehind (?<=\() per trovare ciò che è dopo la parentesi
        HOSTNAME_ONLY=$(echo "$CURRENT_HOST_FULL" | grep -oP '(?<=\()srv-[^)]+')
        PID_HOSTNAME[$PID]=$HOSTNAME_ONLY
    fi
    
    # ${var:-default}: usa "default" se la variabile è vuota o non definita
    HOST_DISPLAY=${PID_MAP[$PID]:-"Sistema/Interno"}
    HNAME=${PID_HOSTNAME[$PID]:-"unknown"}

    # LOGICA 1: Rilevamento trasferimento in corso
    # [[ ... ]]: versione estesa di test, supporta pattern matching con ==
    # *">f"*: pattern che matcha qualsiasi stringa contenente ">f" (flag rsync per file in trasferimento)
    if [[ "$line" == *">f"* ]]; then
        # $(NF-1): penultimo campo (NF = Number of Fields)
        # $NF: ultimo campo
        FILENAME=$(echo "$line" | awk '{print $(NF-1)}')
        SIZE=$(echo "$line" | awk '{print $NF}')
        FULL_PATH="${HNAME}/${FILENAME}"
        # Salva info trasferimento per uso futuro (quando arriverà il messaggio di completamento)
        TRANSFERS[$PID]="$FULL_PATH|$SIZE"
        
        log_line "$TS" "$PID" "$HOST_DISPLAY" "$SIZE" "$FULL_PATH" "IN_PROGRESS"
        continue  # Passa alla prossima iterazione del loop
    fi

    # LOGICA 2: Rilevamento trasferimento completato con successo
    # &&: operatore AND logico - entrambe le condizioni devono essere vere
    # Cerca sia "received" che "sent" nella stessa riga (messaggio di riepilogo rsync)
    if [[ "$line" == *"received"* && "$line" == *"sent"* ]]; then
        if [ -n "${TRANSFERS[$PID]}" ]; then
            # IFS='|': Imposta il separatore di campo per il comando read
            # read -r f_path f_size: legge i valori nelle variabili
            # <<<: here-string - passa la stringa come input standard al comando read
            # Esempio: "percorso|12345" viene diviso in f_path="percorso" e f_size="12345"
            IFS='|' read -r f_path f_size <<< "${TRANSFERS[$PID]}"
            log_line "$TS" "$PID" "$HOST_DISPLAY" "$f_size" "$f_path" "✅ SUCCESS"
            # unset: rimuove una variabile o elemento di array
            unset TRANSFERS[$PID]
        fi
        continue
    fi

    # LOGICA 3: Errore Permessi
    # Rileva errori di accesso negato
    if [[ "$line" == *"Permission denied"* ]]; then
        # Pattern '(?<=")/?[^"]+(?=")': estrae il percorso tra virgolette
        # (?<="): lookbehind - deve essere preceduto da virgolette
        # /?: slash opzionale
        # [^"]+: uno o più caratteri che non sono virgolette
        # (?="): lookahead - deve essere seguito da virgolette
        RAW=$(echo "$line" | grep -oP '(?<=")/?[^"]+(?=")')
        # sed 's|^/||': rimuove lo slash iniziale se presente
        # s: comando substitute
        # |: delimitatore (invece di / per evitare conflitti con i path)
        # ^/: pattern da cercare (slash all'inizio della riga)
        # ||: sostituzione vuota (rimuove)
        FULL_PATH=$(echo "$RAW" | sed 's|^/||')
        log_line "$TS" "$PID" "$HOST_DISPLAY" "---" "$FULL_PATH" "❌ ERROR_PERM"
        unset TRANSFERS[$PID]
        continue
    fi

    # LOGICA 4: Errori Vari di rsync
    if [[ "$line" == *"rsync error:"* ]]; then
        ESITO="❌ ERROR_GENERIC"
        # Codici errore rsync comuni:
        # code 12: errore di connessione
        # code 23: trasferimento parziale (alcuni file non trasferiti)
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