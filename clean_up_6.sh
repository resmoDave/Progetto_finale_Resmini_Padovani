#!/bin/bash
# ============================================================================
# clean_up_6.sh
# ============================================================================
# DESCRIZIONE:
#   Script completo di cleanup e manutenzione per il sistema di backup.
#   Esegue 10 fasi di pulizia, verifica e reportistica.
#
# FUNZIONALITÀ:
#   1. Pulizia file temporanei e parziali
#   2. Pulizia file di sistema (code, offset)
#   3. Rimozione backup obsoleti basati su audit log
#   4. Pulizia directory vuote
#   5. Rotazione e compressione log
#   6. Analisi errori ricorrenti
#   7. Pulizia file Python e cache
#   8. Verifica integrità storage
#   9. Generazione report finale
#   10. Aggiornamento log di sistema
#
# COMANDI BASH UTILIZZATI:
#   - find: ricerca file e directory con criteri complessi
#   - stat: ottiene informazioni sui file (dimensione, timestamp)
#   - du: disk usage - calcola spazio utilizzato
#   - df: disk free - mostra spazio disponibile
#   - sort/uniq: ordinamento e rimozione duplicati
#   - wc: word count - conta righe/parole
#   - chmod: cambia permessi file
#   - gzip: compressione file
# ============================================================================

# CONFIGURAZIONE
# Directory radice dei backup
BACKUP_ROOT="./local_backup"

# File di log sorgente da analizzare
LOG_SOURCE="./audit_clean.log"

# File di log delle operazioni di cleanup
CLEANUP_LOG="./cleanup_audit.log"

# Log del quota killer (per analisi errori)
QUOTA_LOG="./quota_killer.log"

# Parametri di retention (giorni)
RETENTION_DAYS=30        # Giorni dopo cui un backup è considerato obsoleto
COMPRESSION_DAYS=7       # Giorni dopo cui comprimere i log
ERROR_RETENTION_DAYS=3   # Giorni dopo cui rimuovere file temporanei

# Crea il file di log se non esiste
# touch: crea file vuoto o aggiorna timestamp se esiste
touch "$CLEANUP_LOG"

# Funzione per registrare messaggi nel log di cleanup
# $1: messaggio da registrare
# date '+%Y-%m-%d %H:%M:%S': formatta data/ora corrente
log_cleanup() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CLEANUP: $1" >> "$CLEANUP_LOG"
}

# Intestazione output
echo "=== INIZIO PROCEDURA CLEANUP ==="
echo "Data: $(date)"
echo "Log sorgente: $LOG_SOURCE"
echo "Directory backup: $BACKUP_ROOT"
echo ""

log_cleanup "=== Inizio procedura cleanup $(date) ==="

# ============================================================================
# FASE 1: Pulizia file temporanei e parziali
# ============================================================================
# Rimuove file incompleti lasciati da trasferimenti interrotti
echo "FASE 1: Pulizia file temporanei e parziali"
log_cleanup "FASE 1: Pulizia file temporanei"

# find: comando potente per cercare file
#   "$BACKUP_ROOT": directory di partenza
#   -type f: cerca solo file (non directory)
#   \( ... \): raggruppamento di condizioni
#   -name "pattern": match del nome file
#   -o: operatore OR
# | while read -r: processa ogni risultato
find "$BACKUP_ROOT" -type f \( -name ".tmp" -o -name ".part" -o -name ".partial" -o -name ".incomplete" \) | while read -r temp_file; do
    # stat -c%s: ottiene la dimensione del file in bytes
    # 2>/dev/null: scarta eventuali errori
    # || echo "0": valore di default se stat fallisce
    file_size=$(stat -c%s "$temp_file" 2>/dev/null || echo "0")
    
    # Calcolo età del file in giorni
    # date +%s: timestamp Unix corrente (secondi dal 1970)
    # stat -c %Y: timestamp ultima modifica del file
    # $(( )): aritmetica bash
    # 86400: secondi in un giorno (24*60*60)
    file_age=$(( ( $(date +%s) - $(stat -c %Y "$temp_file" 2>/dev/null || echo 0) ) / 86400 ))
    
    # -ge: greater than or equal (maggiore o uguale)
    if [ "$file_age" -ge "$ERROR_RETENTION_DAYS" ]; then
        echo "  Rimuovo: $temp_file (${file_age} giorni, ${file_size} bytes)"
        log_cleanup "Rimosso file temporaneo: $temp_file (età: ${file_age} giorni)"
        rm -f "$temp_file"  # -f: force, non chiede conferma
    fi
done

# ============================================================================
# FASE 2: Pulizia file di sistema (code e offset)
# ============================================================================
echo ""
echo "FASE 2: Pulizia file di sistema"
log_cleanup "FASE 2: Pulizia file di sistema"

# Array di file di sistema da verificare
# Questi file vengono usati dagli altri script per gestire code e stato
queue_files=(".warn_client_offset" ".warn_client_queue")

# Ciclo sull'array
# "${array[@]}": espande tutti gli elementi dell'array
for qfile in "${queue_files[@]}"; do
    if [ -f "./$qfile" ]; then
        # -s: verifica se il file ha dimensione > 0
        # ! -s: vero se il file è vuoto (dimensione 0)
        if [ ! -s "./$qfile" ]; then
            echo "  Rimuovo: $qfile (file vuoto)"
            log_cleanup "Rimosso file vuoto: $qfile"
            rm -f "./$qfile"
        else
            # wc -l: conta le righe del file
            # <: redirezione input (passa il file come input a wc)
            line_count=$(wc -l < "./$qfile" 2>/dev/null || echo "0")
            if [ "$line_count" -eq 0 ]; then
                echo "  Rimuovo: $qfile (zero righe)"
                log_cleanup "Rimosso file zero righe: $qfile"
                rm -f "./$qfile"
            fi
        fi
    fi
done

# ============================================================================
# FASE 3: Pulizia backup obsoleti basati su audit_clean.log
# ============================================================================
# Analizza il log per identificare file non più referenziati
echo ""
echo "FASE 3: Pulizia backup obsoleti"
log_cleanup "FASE 3: Pulizia backup obsoleti"

# Verifica che il file di log esista
if [ -f "$LOG_SOURCE" ]; then
    # declare -A: dichiara un array associativo (chiave-valore)
    # Mappa: nome_file -> ultimo_timestamp
    declare -A file_timestamps
    
    # Legge il log riga per riga
    # IFS=: Internal Field Separator - vuoto per preservare spazi
    # read -r: legge senza interpretare i backslash
    # < "$LOG_SOURCE": redirezione input dal file
    while IFS= read -r line; do
        # =~: operatore di regex matching
        # Salta header, righe vuote e separatori
        if [[ "$line" =~ TIMESTAMP.*PID.*HOST ]] || [[ -z "$line" ]] || [[ "$line" =~ ^-+$ ]]; then
            continue
        fi
        
        # Estrazione campi con awk
        # awk -F'|': usa | come separatore di campo
        # xargs: rimuove spazi iniziali/finali (trim)
        timestamp=$(echo "$line" | awk -F'|' '{print $1}' | xargs)
        resource=$(echo "$line" | awk -F'|' '{print $5}' | xargs)
        
        if [[ -n "$resource" && "$resource" != "---" ]]; then
            # Conversione timestamp in formato Unix
            # ${var:start:length}: estrazione sottostringa
            # ${timestamp:0:10}: estrae YYYY/MM/DD
            # ${timestamp:11:8}: estrae HH:MM:SS
            # date -d "..." +%s: converte data in timestamp Unix
            unix_time=$(date -d "${timestamp:0:10} ${timestamp:11:8}" +%s 2>/dev/null || echo "0")
            
            if [ "$unix_time" -gt 0 ]; then
                # basename: estrae il nome file dal percorso completo
                filename=$(basename "$resource")
                
                if [ -n "$filename" ]; then
                    # Aggiorna il timestamp più recente per questo file
                    current_timestamp="${file_timestamps[$filename]}"
                    # Mantiene il timestamp più recente
                    if [ -z "$current_timestamp" ] || [ "$unix_time" -gt "$current_timestamp" ]; then
                        file_timestamps["$filename"]="$unix_time"
                    fi
                fi
            fi
        fi
    done < "$LOG_SOURCE"
    
    # Analisi file backup per identificare obsoleti
    echo "  Analisi file backup..."
    current_time=$(date +%s)
    
    # Cerca file di backup con estensioni specifiche
    find "$BACKUP_ROOT" -type f \( -name ".dat" -o -name ".tar.gz" -o -name ".gz" -o -name ".sql" \) | while read -r backup_file; do
        filename=$(basename "$backup_file")
        file_time=$(stat -c %Y "$backup_file" 2>/dev/null || echo "0")
        
        # Verifica se il file è presente nel log
        # ${array[key]}: accesso a elemento di array associativo
        if [ -n "${file_timestamps[$filename]}" ]; then
            last_log_time="${file_timestamps[$filename]}"
            # Calcola giorni dall'ultima attività
            days_since_log=$(( (current_time - last_log_time) / 86400 ))
            
            if [ "$days_since_log" -gt "$RETENTION_DAYS" ]; then
                file_size=$(stat -c%s "$backup_file" 2>/dev/null || echo "0")
                # Conversione bytes -> MB (1048576 = 1024*1024)
                file_size_mb=$((file_size / 1048576))
                
                echo "  Rimuovo backup obsoleto: $filename (${days_since_log} giorni senza attività)"
                log_cleanup "Rimosso backup obsoleto: $filename (${days_since_log} giorni, ${file_size_mb}MB)"
                rm -f "$backup_file"
            fi
        else
            # File "orfano" - non presente nel log
            file_age=$(( (current_time - file_time) / 86400 ))
            
            # Per file orfani, usa retention doppia (più prudente)
            if [ "$file_age" -gt $((RETENTION_DAYS * 2)) ]; then
                file_size=$(stat -c%s "$backup_file" 2>/dev/null || echo "0")
                file_size_mb=$((file_size / 1048576))
                
                echo "  Rimuovo backup orfano: $filename (${file_age} giorni, mai nel log)"
                log_cleanup "Rimosso backup orfano: $filename (${file_age} giorni, ${file_size_mb}MB)"
                rm -f "$backup_file"
            fi
        fi
    done
fi

# ============================================================================
# FASE 4: Pulizia directory vuote
# ============================================================================
echo ""
echo "FASE 4: Pulizia directory vuote"
log_cleanup "FASE 4: Pulizia directory vuote"

# find -type d -empty: trova solo directory vuote
find "$BACKUP_ROOT" -type d -empty | while read -r empty_dir; do
    # Protezione per non rimuovere directory principali
    # =~: regex matching
    # ^$BACKUP_ROOT/[^/]+$: matcha solo directory al primo livello
    if [[ "$empty_dir" != "$BACKUP_ROOT" ]] && [[ ! "$empty_dir" =~ ^$BACKUP_ROOT/[^/]+$ ]]; then
        echo "  Rimuovo directory vuota: $empty_dir"
        log_cleanup "Rimosso directory vuota: $empty_dir"
        # rmdir: rimuove solo directory vuote (più sicuro di rm -r)
        # 2>/dev/null: nasconde errori se la directory non è più vuota
        # || true: continua anche se rmdir fallisce
        rmdir "$empty_dir" 2>/dev/null || true
    fi
done

# ============================================================================
# FASE 5: Rotazione e compressione log vecchi
# ============================================================================
echo ""
echo "FASE 5: Rotazione e compressione log"
log_cleanup "FASE 5: Rotazione log"

# Array di file di log da gestire
log_files=("audit_clean.log" "quota_killer.log" "cleanup_audit.log")

for logfile in "${log_files[@]}"; do
    if [ -f "./$logfile" ]; then
        file_size=$(stat -c%s "./$logfile" 2>/dev/null || echo "0")
        file_size_mb=$((file_size / 1048576))
        
        # Se il log supera 10MB, esegue rotazione
        if [ "$file_size_mb" -gt 10 ]; then
            # Genera timestamp per il nome del file archiviato
            rotate_date=$(date +%Y%m%d_%H%M%S)
            echo "  Ruoto log: $logfile (${file_size_mb}MB)"
            log_cleanup "Rotazione log: $logfile -> ${logfile}.${rotate_date}"
            
            # gzip -c: comprime e scrive su stdout (non modifica l'originale)
            # >: redirezione output su nuovo file
            gzip -c "./$logfile" > "./${logfile}.${rotate_date}.gz"
            
            # tail -N: estrae le ultime N righe
            # Mantieni solo le ultime 1000 righe nel file originale
            tail -1000 "./$logfile" > "./${logfile}.tmp"
            # mv: rinomina/muove il file
            mv "./${logfile}.tmp" "./$logfile"
        fi
    fi
done

# Sposta log compressi vecchi in directory archivio
# -mtime +N: file modificati più di N giorni fa
find . -name ".log..gz" -type f -mtime +$COMPRESSION_DAYS | while read -r old_log; do
    echo "  Archivio log vecchio: $(basename "$old_log")"
    log_cleanup "Archiviato log vecchio: $(basename "$old_log")"
    # mkdir -p: crea directory se non esiste
    mkdir -p "./archived_logs"
    mv "$old_log" "./archived_logs/" 2>/dev/null || true
done

# ============================================================================
# FASE 6: Analisi errori ricorrenti dal log
# ============================================================================
echo ""
echo "FASE 6: Analisi errori ricorrenti"
log_cleanup "FASE 6: Analisi errori"

if [ -f "$LOG_SOURCE" ]; then
    # Pattern di errore da cercare
    error_patterns=("ERROR_CONN" "ERROR_PERM" "ERROR_PARTIAL")
    
    for pattern in "${error_patterns[@]}"; do
        echo "  Analisi errori $pattern:"
        
        # Pipeline complessa per contare errori per cliente:
        # grep: filtra righe con l'errore specifico
        # awk -F'|' '{print $3}': estrae il campo host (colonna 3)
        # sed 's/.*(//;s/)//': rimuove parentesi per estrarre solo l'ID
        #   s/.*(//: sostituisce tutto fino a ( con nulla
        #   s/)//: rimuove la parentesi chiusa
        # sort: ordina alfabeticamente
        # uniq -c: conta occorrenze duplicate (richiede input ordinato)
        # sort -rn: ordina numericamente in ordine decrescente
        grep "❌ $pattern" "$LOG_SOURCE" | awk -F'|' '{print $3}' | sed 's/.*(//;s/)//' | sort | uniq -c | sort -rn | while read -r count client; do
            # Soglia di 3 errori per considerare "ricorrente"
            if [ "$count" -gt 3 ]; then
                echo "    ATTENZIONE: $client ha $count errori $pattern"
                log_cleanup "Cliente con errori ricorrenti: $client - $count errori $pattern"
                
                # Crea file di warning nella directory del cliente
                if [ -d "$BACKUP_ROOT/$client" ]; then
                    warning_file="$BACKUP_ROOT/$client/WARNING_${pattern}.txt"
                    echo "ATTENZIONE: Rilevati $count errori $pattern" > "$warning_file"
                    echo "Data rilevazione: $(date)" >> "$warning_file"
                    echo "Si consiglia verifica connessione/configurazione" >> "$warning_file"
                fi
            fi
        done
    done
    
    # Verifica backup completi mancanti nelle ultime 24 ore
    echo "  Verifica backup completi:"
    
    # grep -oE: estrae solo la parte che matcha la regex estesa
    # Pattern 'srv-(web|db)-[0-9]{2}': matcha ID server come srv-web-01
    # sort -u: ordina e rimuove duplicati
    clients_from_log=$(grep -oE 'srv-(web|db)-[0-9]{2}' "$LOG_SOURCE" | sort -u)
    
    for client in $clients_from_log; do
        # Conta successi nelle ultime 24 ore
        # date -d '24 hours ago': calcola la data di 24 ore fa
        recent_success=$(grep "$client" "$LOG_SOURCE" | grep "✅ SUCCESS" | grep "$(date -d '24 hours ago' '+%Y/%m/%d')" | wc -l)
        
        if [ "$recent_success" -eq 0 ]; then
            echo "    ATTENZIONE: $client senza backup di successo nelle ultime 24h"
            log_cleanup "Cliente senza backup recente: $client"
        fi
    done
fi

# ============================================================================
# FASE 7: Pulizia file Python e cache
# ============================================================================
echo ""
echo "FASE 7: Pulizia ambientale"
log_cleanup "FASE 7: Pulizia ambientale"

# Rimozione file Python compilati (.pyc)
# find -delete: trova ed elimina in un solo comando
# &&: esegue echo solo se find ha successo
find . -name "*.pyc" -delete 2>/dev/null && echo "  Rimossi file .pyc"

# Rimozione directory __pycache__
# -exec rm -rf {} +: esegue rm -rf su tutti i file trovati
# {}: placeholder per i file trovati
# +: passa tutti i file a un solo comando rm (più efficiente)
find . -name "_pycache" -type d -exec rm -rf {} + 2>/dev/null && echo "  Rimosse directory __pycache_"

# Rimozione file di swap Vim
find . -name "*.swp" -delete 2>/dev/null && echo "  Rimossi file .swp"
find . -name "*.swo" -delete 2>/dev/null && echo "  Rimossi file .swo"

# ============================================================================
# FASE 8: Verifica integrità storage
# ============================================================================
echo ""
echo "FASE 8: Verifica integrità storage"
log_cleanup "FASE 8: Verifica integrità"

# Controllo spazio disco
# df -h: disk free in formato human-readable
# awk 'NR==2': processa solo la seconda riga (salta header)
# {print $5}: stampa il quinto campo (Use%)
# sed 's/%//': rimuove il simbolo %
disk_usage=$(df -h . | awk 'NR==2 {print $5}' | sed 's/%//')
echo "  Utilizzo disco: $disk_usage%"

# Alert se utilizzo superiore all'80%
if [ "$disk_usage" -gt 80 ]; then
    echo "  ATTENZIONE: Utilizzo disco superiore all'80%"
    log_cleanup "ATTENZIONE: Utilizzo disco al ${disk_usage}%"
    
    # Calcola spazio per ogni cliente
    echo "  Spazio per cliente:"
    # Loop sulle subdirectory
    for client_dir in "$BACKUP_ROOT"/*/; do
        if [ -d "$client_dir" ]; then
            client=$(basename "$client_dir")
            # du -sh: disk usage in formato human-readable, somma totale
            # cut -f1: estrae solo la dimensione (primo campo)
            size=$(du -sh "$client_dir" 2>/dev/null | cut -f1)
            echo "    $client: $size"
        fi
    done
fi

# Verifica e correzione permessi directory
echo "  Verifica permessi:"
# ! -perm 0750: file che NON hanno i permessi specificati
# 0750 = rwxr-x--- (proprietario: tutto, gruppo: lettura/esecuzione, altri: nulla)
find "$BACKUP_ROOT" -type d ! -perm 0750 2>/dev/null | while read -r dir; do
    echo "    Correggo permessi: $dir"
    chmod 0750 "$dir" 2>/dev/null
done

# Verifica permessi file
# 0640 = rw-r----- (proprietario: lettura/scrittura, gruppo: lettura, altri: nulla)
find "$BACKUP_ROOT" -type f ! -perm 0640 2>/dev/null | while read -r file; do
    echo "    Correggo permessi: $(basename "$file")"
    chmod 0640 "$file" 2>/dev/null
done

# ============================================================================
# FASE 9: Generazione report finale
# ============================================================================
echo ""
echo "FASE 9: Generazione report"
log_cleanup "FASE 9: Generazione report"

# Nome del file report con timestamp
report_file="./cleanup_report_$(date +%Y%m%d).txt"

# Scrittura intestazione report
# >: crea/sovrascrive il file
echo "=== REPORT CLEANUP BACKUP ===" > "$report_file"
echo "Data esecuzione: $(date)" >> "$report_file"
echo "Directory backup: $BACKUP_ROOT" >> "$report_file"
echo "" >> "$report_file"

# Statistiche spazio
echo "=== STATISTICHE SPAZIO ===" >> "$report_file"
total_space=$(du -sh "$BACKUP_ROOT" 2>/dev/null | cut -f1)
echo "Spazio totale utilizzato: $total_space" >> "$report_file"
echo "" >> "$report_file"

# Elenco clienti presenti
echo "=== CLIENTI PRESENTI ===" >> "$report_file"
client_count=0
for client_dir in "$BACKUP_ROOT"/*/; do
    if [ -d "$client_dir" ]; then
        # Incremento contatore
        # $(( )): aritmetica bash
        client_count=$((client_count + 1))
        client=$(basename "$client_dir")
        client_size=$(du -sh "$client_dir" 2>/dev/null | cut -f1)
        # Conta file nella directory del cliente
        # wc -l: conta le righe (una per ogni file trovato)
        file_count=$(find "$client_dir" -type f | wc -l)
        echo "$client: $client_size ($file_count file)" >> "$report_file"
    fi
done
echo "Totale clienti: $client_count" >> "$report_file"
echo "" >> "$report_file"

# Errori recenti (ultime 24 ore)
if [ -f "$LOG_SOURCE" ]; then
    echo "=== ERRORI RECENTI (ultime 24h) ===" >> "$report_file"
    # || true: evita errori se grep non trova nulla
    recent_errors=$(grep "❌ ERROR" "$LOG_SOURCE" | grep "$(date -d '24 hours ago' '+%Y/%m/%d')" || true)
    
    if [ -n "$recent_errors" ]; then
        echo "$recent_errors" >> "$report_file"
    else
        echo "Nessun errore rilevato nelle ultime 24 ore" >> "$report_file"
    fi
    echo "" >> "$report_file"
fi

# Statistiche operazioni di cleanup
echo "=== STATISTICHE CLEANUP ===" >> "$report_file"
cleanup_lines=$(wc -l < "$CLEANUP_LOG" 2>/dev/null || echo "0")
echo "Operazioni di cleanup registrate: $cleanup_lines" >> "$report_file"
echo "" >> "$report_file"

# Sezione avvisi
echo "=== AVVISI ===" >> "$report_file"
if [ "$disk_usage" -gt 80 ]; then
    echo "⚠️  ATTENZIONE: Utilizzo disco critico ($disk_usage%)" >> "$report_file"
fi

# grep -q: quiet mode, non stampa output, restituisce solo exit code
# Utile per verificare se un pattern esiste
if grep -q "ATTENZIONE" "$CLEANUP_LOG"; then
    echo "⚠️  Sono stati rilevati problemi durante il cleanup" >> "$report_file"
fi

echo "" >> "$report_file"
echo "=== FINE REPORT ===" >> "$report_file"

echo "Report generato: $report_file"
log_cleanup "Report generato: $report_file"

# ============================================================================
# FASE 10: Aggiornamento log di sistema
# ============================================================================
echo ""
echo "FASE 10: Aggiornamento log di sistema"

# Genera timestamp formattato
timestamp=$(date '+%Y/%m/%d %H:%M:%S')

# $$: variabile speciale contenente il PID del processo corrente
pid=$$

# Crea riga di riepilogo nel formato del log
summary_line="Sistema/Interno              | $pid  | Sistema/Interno              | ---          | cleanup/automated_maintenance               | ✅ CLEANUP_COMPLETE"

# Aggiunge la riga al log principale
echo "$summary_line" >> "$LOG_SOURCE"
log_cleanup "Riga di riepilogo aggiunta a audit_clean.log"

# Conteggio file rimossi
# grep -c: conta le righe che matchano il pattern
files_removed=$(grep -c "Rimosso" "$CLEANUP_LOG" || echo "0")
space_freed="N/A"  # Potrebbe essere calcolato più precisamente

# Riepilogo finale
echo ""
echo "=== CLEANUP COMPLETATO ==="
echo "File rimossi: $files_removed"
echo "Spazio liberato: $space_freed"
echo "Report: $report_file"
echo "Log cleanup: $CLEANUP_LOG"

log_cleanup "=== Fine procedura cleanup $(date) ==="
log_cleanup "File rimossi: $files_removed"
log_cleanup "Spazio liberato: $space_freed"

echo ""
echo "Procedura cleanup completata con successo!"