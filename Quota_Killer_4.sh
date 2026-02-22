#!/bin/bash
# ============================================================================
# Quota_Killer_4.sh
# ============================================================================
# DESCRIZIONE:
#   Script di monitoraggio che controlla le dimensioni dei trasferimenti file
#   in corso. Se un trasferimento supera la quota massima consentita, lo script
#   termina forzatamente il processo rsync associato.
#
# UTILIZZO:
#   ./Quota_Killer_4.sh [quota_massima_in_byte]
#   Esempio: ./Quota_Killer_4.sh 2097152  # 2MB
#   Default: 1048576 byte (1MB)
#
# FUNZIONALITÀ:
#   - Monitora il file audit_clean.log per nuovi trasferimenti
#   - Verifica se la dimensione supera la quota configurata
#   - Termina i processi che violano la quota con kill -9
#   - Registra tutte le azioni in quota_killer.log
#
# COMANDI BASH UTILIZZATI:
#   - ${var:-default}: assegna un valore di default se la variabile è vuota
#   - =~: operatore di regex matching
#   - (( )): aritmetica bash per confronti numerici
#   - ps -p: verifica se un processo è in esecuzione
#   - kill -9: invia segnale SIGKILL (terminazione immediata)
#   - awk -F: specifica un separatore di campo personalizzato
#   - tr -d: elimina caratteri specificati
# ============================================================================

# File di log da monitorare (input)
AUDIT_LOG="audit_clean.log"

# File di log dove registrare le azioni di kill
LOG_KILLER="quota_killer.log"

# --- CONFIGURAZIONE QUOTA ---
# Quota predefinita: 1048576 byte = 1 MB
DEFAULT_QUOTA=1048576

# ${1:-$DEFAULT_QUOTA}: 
#   Se $1 (primo argomento) è definito e non vuoto, usa $1
#   Altrimenti usa $DEFAULT_QUOTA come valore di default
MAX_QUOTA=${1:-$DEFAULT_QUOTA}

# Validazione input: verifica che MAX_QUOTA sia un numero
# =~: operatore di regex matching in bash
# ^[0-9]+$: pattern che matcha solo cifre dall'inizio (^) alla fine ($)
# !: nega il risultato del test
if ! [[ "$MAX_QUOTA" =~ ^[0-9]+$ ]]; then
    echo "Error: Quota must be a number."
    exit 1
fi

echo "Starting monitor... Using MAX_QUOTA: $MAX_QUOTA"

# MONITORAGGIO CONTINUO DEL LOG
# tail -Fn0:
#   -F: follow - segue il file anche se viene ruotato/ricreato
#   -n0: non mostra nessuna riga esistente, solo le nuove
# Questo significa che lo script reagisce solo a NUOVI eventi
tail -Fn0 "$AUDIT_LOG" | while read -r line; do
    
    # 1. Filtra solo le righe che indicano trasferimento in corso
    # *IN_PROGRESS*: pattern matching - qualsiasi riga contenente "IN_PROGRESS"
    if [[ "$line" == *"IN_PROGRESS"* ]]; then
        
        # ESTRAZIONE CAMPI DALLA RIGA DI LOG
        # La riga ha formato: timestamp|PID|host|dimensione|percorso|stato
        
        # awk -F ' *\\| *': 
        #   -F: specifica il separatore di campo
        #   ' *\\| *': regex come separatore - il pipe con spazi opzionali
        #   \\|: escape del pipe (carattere speciale in regex)
        #   {print $2}: stampa il secondo campo (PID)
        PID=$(echo "$line" | awk -F ' *\\| *' '{print $2}')
        HOST_RAW=$(echo "$line" | awk -F ' *\\| *' '{print $3}')
        SIZE=$(echo "$line" | awk -F ' *\\| *' '{print $4}')
        
        # Estrae l'ID dell'host dal campo HOST_RAW
        # grep -oP '(?<=srv-)[^)]+': 
        #   (?<=srv-): lookbehind - trova testo dopo "srv-"
        #   [^)]+: uno o più caratteri che non sono parentesi chiusa
        # tr -d ')': elimina eventuali parentesi rimaste
        HOST_ID=$(echo "$HOST_RAW" | grep -oP '(?<=srv-)[^)]+' | tr -d ')')
        
        # 2. CONFRONTO CON LA QUOTA MASSIMA
        # (( )): aritmetica bash - permette confronti numerici
        # >: operatore "maggiore di" in contesto aritmetico
        if (( SIZE > MAX_QUOTA )); then
            # 3. VERIFICA PROCESSO ATTIVO
            # ps -p "$PID": verifica se il processo con quel PID esiste
            # > /dev/null: scarta l'output (ci interessa solo l'exit code)
            if ps -p "$PID" > /dev/null; then
                # TERMINAZIONE FORZATA DEL PROCESSO
                # kill -9: invia segnale SIGKILL
                #   -9: numero del segnale SIGKILL (terminazione immediata)
                #   Il processo non può intercettare o ignorare SIGKILL
                kill -9 "$PID"
                
                # Registra l'azione nel log
                # $(date): inserisce timestamp corrente
                # >>: append al file (non sovrascrive)
                echo "$(date) | Killed active PID $PID ($HOST_ID) - Request size $SIZE > $MAX_QUOTA" >> "$LOG_KILLER"
            else
                # Il processo è già terminato (race condition)
                echo "$(date) | PID $PID not found (already finished?)" >> "$LOG_KILLER"
            fi
        fi
    fi
done