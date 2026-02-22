#!/bin/bash

# ============================================================================
# split_logs_by_id_5.sh
# ============================================================================
# DESCRIZIONE:
#   Script per estrarre righe di log specifiche per un cliente/server.
#   Filtra il file audit_clean.log in base all ID cliente e opzionalmente
#   per un range di date.
# UTILIZZO:
#   ./split_logs_by_id_5.sh <ID_CLIENTE>                     # Tutto lo storico
#   ./split_logs_by_id_5.sh <ID_CLIENTE> <DATA_INI> <DATA_FINE>  # Con date
#   Esempio: ./split_logs_by_id_5.sh srv-web-01 2024/01/01 2024/12/31
# OUTPUT:
#   Crea un file <ID_CLIENTE>_estratto.log con le righe filtrate
# COMANDI BASH E AWK UTILIZZATI:
#   - awk:        linguaggio di elaborazione testo potente e flessibile
#   - awk -v:     passa variabili shell allo script awk
#   - awk BEGIN:  blocco eseguito prima di processare le righe
#   - awk FS/OFS: Field Separator / Output Field Separator
#   - gsub():     funzione awk per sostituzione globale
#   - index():    funzione awk per cercare sottostringhe
#   - split():    funzione awk per dividere stringhe in array
#   - tr -d:      elimina caratteri specificati
# ============================================================================

# File di log sorgente (input)
FILE_LOG="audit_clean.log"

# Verifica che il file di log esista
# -f: verifica se il file esiste ed e un file regolare
if [ ! -f "$FILE_LOG" ]; then
    echo "Errore: Il file '$FILE_LOG' non è presente."
    exit 1
fi

# VALIDAZIONE ARGOMENTI
# $#: numero di argomenti passati allo script
# -ne: "not equal" - diverso da
# &&: AND logico
# Accetta 1 argomento (solo ID) oppure 3 argomenti (ID + date)
if [ "$#" -ne 3 ] && [ "$#" -ne 1 ]; then
    echo "Uso: $0 <ID_CLIENTE> [<DATA_INIZIO> <DATA_FINE>]"
    exit 1
fi

# Primo argomento: ID del cliente/server da cercare
ID_CLIENTE="$1"

# Gestione del range di date
if [ "$#" -eq 3 ]; then
    # Formattazione date: rimuove gli slash per ottenere YYYYMMDD
    # tr -d "/": elimina tutti i caratteri "/" dalla stringa
    # Esempio: "2024/01/15" diventa "20240115"
    DATA_INIZIO_FMT=$(echo "$2" | tr -d "/")
    DATA_FINE_FMT=$(echo "$3" | tr -d "/")
    MSG="Log estratto per $ID_CLIENTE dal $2 al $3"
else
    # Se non sono specificate date, usa valori estremi per prendere tutto
    DATA_INIZIO_FMT="00000000"   # Data minima possibile
    DATA_FINE_FMT="99999999"     # Data massima possibile
    MSG="Log estratto per $ID_CLIENTE (Tutto lo storico)"
fi

# Nome del file di output
# ${VAR}: espansione della variabile (piu sicuro con le graffe)
OUT_FILE="${ID_CLIENTE}_estratto.log"

# ============================================================================
# AWK SCRIPT: Elaborazione e filtraggio del log
# ============================================================================
# awk -v VAR=VAL: passa variabili dalla shell allo script awk
#   -v id="$ID_CLIENTE":       passa l ID cliente
#   -v di="$DATA_INIZIO_FMT":  passa data inizio
#   -v df="$DATA_FINE_FMT":    passa data fine
# BEGIN { FS="|"; OFS="|" }:
#   FS  (Field Separator):        separatore di input (il pipe)
#   OFS (Output Field Separator):  separatore di output (pipe)
#   Viene eseguito una sola volta prima di leggere le righe
awk -v id="$ID_CLIENTE" -v di="$DATA_INIZIO_FMT" -v df="$DATA_FINE_FMT" '
BEGIN { FS="|"; OFS="|" }
{
    # 1. PULIZIA RITORNI A CAPO WINDOWS
    # gsub(regex, replacement, string): sostituzione globale
    # /\r/: regex che matcha il carriage return (\r)
    # Rimuove i caratteri \r (Windows line endings)
    gsub(/\r/, "", $0)

    # 2. PULIZIA SPAZI BIANCHI
    # Rimuove spazi e tab all inizio e alla fine dei campi
    # /^[ \t]+/: regex - inizio riga seguito da spazi o tab (uno o piu)
    # |: operatore OR in regex
    # [ \t]+$/: spazi o tab alla fine della riga
    # $1 e $5 sono i campi 1 (data) e 5 (percorso)
    gsub(/^[ \t]+|[ \t]+$/, "", $1)
    gsub(/^[ \t]+|[ \t]+$/, "", $5)

    # 3. ESTRAZIONE DATA PER CONFRONTO
    # split(string, array, separator): divide una stringa in un array
    # $1 contiene "YYYY/MM/DD HH:MM:SS"
    # split divide per spazio, a[1] = "YYYY/MM/DD"
    split($1, a, " ")
    data_pulita = a[1]

    # Rimuove gli slash dalla data per ottenere YYYYMMDD
    # /\//: regex che matcha lo slash (va escapato)
    gsub(/\//, "", data_pulita)

    # 4. LOGICA DI FILTRAGGIO
    # index(string, substring): restituisce la posizione della sottostringa
    #   Restituisce 0 se non trovata, >0 se trovata
    # Verifica se l ID e presente nel percorso (campo 5)
    if (index($5, id) > 0) {
        # Verifica se la data e nel range specificato
        # Confronto stringhe funziona perche YYYYMMDD e ordinabile
        if (data_pulita >= di && data_pulita <= df) {
            print $0
        }
    }
}
' "$FILE_LOG" > "$OUT_FILE"

# Redirezione output: > crea/sovrascrive il file di output
echo "$MSG in file: $OUT_FILE"