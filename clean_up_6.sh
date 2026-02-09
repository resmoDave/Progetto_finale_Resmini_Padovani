#!/bin/bash
# Script 06 - Cleanup e Manutenzione Log
# Basato su audit_clean.log e struttura backup locale

BACKUP_ROOT="./local_backup"
LOG_SOURCE="./audit_clean.log"
CLEANUP_LOG="./cleanup_audit.log"
QUOTA_LOG="./quota_killer.log"
RETENTION_DAYS=30
COMPRESSION_DAYS=7
ERROR_RETENTION_DAYS=3

# Crea log di cleanup se non esiste
touch "$CLEANUP_LOG"

log_cleanup() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CLEANUP: $1" >> "$CLEANUP_LOG"
}

echo "=== INIZIO PROCEDURA CLEANUP ==="
echo "Data: $(date)"
echo "Log sorgente: $LOG_SOURCE"
echo "Directory backup: $BACKUP_ROOT"
echo ""

log_cleanup "=== Inizio procedura cleanup $(date) ==="

# FASE 1: Pulizia file temporanei e parziali
echo "FASE 1: Pulizia file temporanei e parziali"
log_cleanup "FASE 1: Pulizia file temporanei"

# Cerca file .tmp, .part, .partial in tutte le directory
find "$BACKUP_ROOT" -type f \( -name ".tmp" -o -name ".part" -o -name ".partial" -o -name ".incomplete" \) | while read -r temp_file; do
    file_size=$(stat -c%s "$temp_file" 2>/dev/null || echo "0")
    file_age=$(( ( $(date +%s) - $(stat -c %Y "$temp_file" 2>/dev/null || echo 0) ) / 86400 ))
    
    if [ "$file_age" -ge "$ERROR_RETENTION_DAYS" ]; then
        echo "  Rimuovo: $temp_file (${file_age} giorni, ${file_size} bytes)"
        log_cleanup "Rimosso file temporaneo: $temp_file (età: ${file_age} giorni)"
        rm -f "$temp_file"
    fi
done

# FASE 2: Pulizia file di coda e offset
echo ""
echo "FASE 2: Pulizia file di sistema"
log_cleanup "FASE 2: Pulizia file di sistema"

# File di coda
queue_files=(".warn_client_offset" ".warn_client_queue")

for qfile in "${queue_files[@]}"; do
    if [ -f "./$qfile" ]; then
        if [ ! -s "./$qfile" ]; then
            echo "  Rimuovo: $qfile (file vuoto)"
            log_cleanup "Rimosso file vuoto: $qfile"
            rm -f "./$qfile"
        else
            # Verifica se contiene dati validi
            line_count=$(wc -l < "./$qfile" 2>/dev/null || echo "0")
            if [ "$line_count" -eq 0 ]; then
                echo "  Rimuovo: $qfile (zero righe)"
                log_cleanup "Rimosso file zero righe: $qfile"
                rm -f "./$qfile"
            fi
        fi
    fi
done

# FASE 3: Pulizia backup obsoleti basati su audit_clean.log
echo ""
echo "FASE 3: Pulizia backup obsoleti"
log_cleanup "FASE 3: Pulizia backup obsoleti"

# Estrai lista file di backup da audit_clean.log
if [ -f "$LOG_SOURCE" ]; then
    # Crea mappa file -> ultima modifica
    declare -A file_timestamps
    
    while IFS= read -r line; do
        # Salta header e linee vuote
        if [[ "$line" =~ TIMESTAMP.*PID.*HOST ]] || [[ -z "$line" ]] || [[ "$line" =~ ^-+$ ]]; then
            continue
        fi
        
        # Estrai timestamp e percorso risorsa
        timestamp=$(echo "$line" | awk -F'|' '{print $1}' | xargs)
        resource=$(echo "$line" | awk -F'|' '{print $5}' | xargs)
        
        if [[ -n "$resource" && "$resource" != "---" ]]; then
            # Converti timestamp in formato Unix
            unix_time=$(date -d "${timestamp:0:10} ${timestamp:11:8}" +%s 2>/dev/null || echo "0")
            
            if [ "$unix_time" -gt 0 ]; then
                # Estrai solo il nome file (ultima parte del percorso)
                filename=$(basename "$resource")
                
                if [ -n "$filename" ]; then
                    # Aggiorna timestamp più recente per questo file
                    current_timestamp="${file_timestamps[$filename]}"
                    if [ -z "$current_timestamp" ] || [ "$unix_time" -gt "$current_timestamp" ]; then
                        file_timestamps["$filename"]="$unix_time"
                    fi
                fi
            fi
        fi
    done < "$LOG_SOURCE"
    
    # Ora cerca file obsoleti
    echo "  Analisi file backup..."
    current_time=$(date +%s)
    
    find "$BACKUP_ROOT" -type f \( -name ".dat" -o -name ".tar.gz" -o -name ".gz" -o -name ".sql" \) | while read -r backup_file; do
        filename=$(basename "$backup_file")
        file_time=$(stat -c %Y "$backup_file" 2>/dev/null || echo "0")
        
        # Verifica se il file è nel log
        if [ -n "${file_timestamps[$filename]}" ]; then
            last_log_time="${file_timestamps[$filename]}"
            days_since_log=$(( (current_time - last_log_time) / 86400 ))
            
            if [ "$days_since_log" -gt "$RETENTION_DAYS" ]; then
                file_size=$(stat -c%s "$backup_file" 2>/dev/null || echo "0")
                file_size_mb=$((file_size / 1048576))
                
                echo "  Rimuovo backup obsoleto: $filename (${days_since_log} giorni senza attività)"
                log_cleanup "Rimosso backup obsoleto: $filename (${days_since_log} giorni, ${file_size_mb}MB)"
                rm -f "$backup_file"
            fi
        else
            # File non nel log - verifica età
            file_age=$(( (current_time - file_time) / 86400 ))
            
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

# FASE 4: Pulizia directory vuote
echo ""
echo "FASE 4: Pulizia directory vuote"
log_cleanup "FASE 4: Pulizia directory vuote"

# Trova e rimuove directory vuote ricorsivamente
find "$BACKUP_ROOT" -type d -empty | while read -r empty_dir; do
    # Non rimuovere le directory principali
    if [[ "$empty_dir" != "$BACKUP_ROOT" ]] && [[ ! "$empty_dir" =~ ^$BACKUP_ROOT/[^/]+$ ]]; then
        echo "  Rimuovo directory vuota: $empty_dir"
        log_cleanup "Rimosso directory vuota: $empty_dir"
        rmdir "$empty_dir" 2>/dev/null || true
    fi
done

# FASE 5: Rotazione e compressione log vecchi
echo ""
echo "FASE 5: Rotazione e compressione log"
log_cleanup "FASE 5: Rotazione log"

# Log da gestire
log_files=("audit_clean.log" "quota_killer.log" "cleanup_audit.log")

for logfile in "${log_files[@]}"; do
    if [ -f "./$logfile" ]; then
        file_size=$(stat -c%s "./$logfile" 2>/dev/null || echo "0")
        file_size_mb=$((file_size / 1048576))
        
        # Se il log supera 10MB, ruota
        if [ "$file_size_mb" -gt 10 ]; then
            rotate_date=$(date +%Y%m%d_%H%M%S)
            echo "  Ruoto log: $logfile (${file_size_mb}MB)"
            log_cleanup "Rotazione log: $logfile -> ${logfile}.${rotate_date}"
            
            # Comprimi il vecchio log
            gzip -c "./$logfile" > "./${logfile}.${rotate_date}.gz"
            
            # Mantieni solo le ultime 1000 righe
            tail -1000 "./$logfile" > "./${logfile}.tmp"
            mv "./${logfile}.tmp" "./$logfile"
        fi
    fi
done

# Comprimi log vecchi (> COMPRESSION_DAYS giorni)
find . -name ".log..gz" -type f -mtime +$COMPRESSION_DAYS | while read -r old_log; do
    echo "  Archivio log vecchio: $(basename "$old_log")"
    log_cleanup "Archiviato log vecchio: $(basename "$old_log")"
    # Potrebbero essere già compressi, li spostiamo in una directory archive
    mkdir -p "./archived_logs"
    mv "$old_log" "./archived_logs/" 2>/dev/null || true
done

# FASE 6: Analisi errori ricorrenti dal log
echo ""
echo "FASE 6: Analisi errori ricorrenti"
log_cleanup "FASE 6: Analisi errori"

if [ -f "$LOG_SOURCE" ]; then
    # Estrai clienti con errori ricorrenti
    error_patterns=("ERROR_CONN" "ERROR_PERM" "ERROR_PARTIAL")
    
    for pattern in "${error_patterns[@]}"; do
        echo "  Analisi errori $pattern:"
        
        # Conta errori per IP/Cliente
        grep "❌ $pattern" "$LOG_SOURCE" | awk -F'|' '{print $3}' | sed 's/.*(//;s/)//' | sort | uniq -c | sort -rn | while read -r count client; do
            if [ "$count" -gt 3 ]; then
                echo "    ATTENZIONE: $client ha $count errori $pattern"
                log_cleanup "Cliente con errori ricorrenti: $client - $count errori $pattern"
                
                # Verifica se il cliente ha una directory backup
                if [ -d "$BACKUP_ROOT/$client" ]; then
                    # Crea file di warning
                    warning_file="$BACKUP_ROOT/$client/WARNING_${pattern}.txt"
                    echo "ATTENZIONE: Rilevati $count errori $pattern" > "$warning_file"
                    echo "Data rilevazione: $(date)" >> "$warning_file"
                    echo "Si consiglia verifica connessione/configurazione" >> "$warning_file"
                fi
            fi
        done
    done
    
    # Verifica backup completi mancanti
    echo "  Verifica backup completi:"
    
    # Lista clienti dal log
    clients_from_log=$(grep -oE 'srv-(web|db)-[0-9]{2}' "$LOG_SOURCE" | sort -u)
    
    for client in $clients_from_log; do
        # Conta successi nelle ultime 24 ore
        recent_success=$(grep "$client" "$LOG_SOURCE" | grep "✅ SUCCESS" | grep "$(date -d '24 hours ago' '+%Y/%m/%d')" | wc -l)
        
        if [ "$recent_success" -eq 0 ]; then
            echo "    ATTENZIONE: $client senza backup di successo nelle ultime 24h"
            log_cleanup "Cliente senza backup recente: $client"
        fi
    done
fi

# FASE 7: Pulizia file Python e cache
echo ""
echo "FASE 7: Pulizia ambientale"
log_cleanup "FASE 7: Pulizia ambientale"

# File Python compilati
find . -name "*.pyc" -delete 2>/dev/null && echo "  Rimossi file .pyc"
find . -name "_pycache" -type d -exec rm -rf {} + 2>/dev/null && echo "  Rimosse directory __pycache_"

# File temporanei generici
find . -name "*.swp" -delete 2>/dev/null && echo "  Rimossi file .swp"
find . -name "*.swo" -delete 2>/dev/null && echo "  Rimossi file .swo"

# FASE 8: Verifica integrità storage
echo ""
echo "FASE 8: Verifica integrità storage"
log_cleanup "FASE 8: Verifica integrità"

# Controlla spazio disco
disk_usage=$(df -h . | awk 'NR==2 {print $5}' | sed 's/%//')
echo "  Utilizzo disco: $disk_usage%"

if [ "$disk_usage" -gt 80 ]; then
    echo "  ATTENZIONE: Utilizzo disco superiore all'80%"
    log_cleanup "ATTENZIONE: Utilizzo disco al ${disk_usage}%"
    
    # Calcola spazio utilizzato per cliente
    echo "  Spazio per cliente:"
    for client_dir in "$BACKUP_ROOT"/*/; do
        if [ -d "$client_dir" ]; then
            client=$(basename "$client_dir")
            size=$(du -sh "$client_dir" 2>/dev/null | cut -f1)
            echo "    $client: $size"
        fi
    done
fi

# Verifica permessi directory
echo "  Verifica permessi:"
find "$BACKUP_ROOT" -type d ! -perm 0750 2>/dev/null | while read -r dir; do
    echo "    Correggo permessi: $dir"
    chmod 0750 "$dir" 2>/dev/null
done

find "$BACKUP_ROOT" -type f ! -perm 0640 2>/dev/null | while read -r file; do
    echo "    Correggo permessi: $(basename "$file")"
    chmod 0640 "$file" 2>/dev/null
done

# FASE 9: Generazione report finale
echo ""
echo "FASE 9: Generazione report"
log_cleanup "FASE 9: Generazione report"

report_file="./cleanup_report_$(date +%Y%m%d).txt"

echo "=== REPORT CLEANUP BACKUP ===" > "$report_file"
echo "Data esecuzione: $(date)" >> "$report_file"
echo "Directory backup: $BACKUP_ROOT" >> "$report_file"
echo "" >> "$report_file"

# Statistiche spazio
echo "=== STATISTICHE SPAZIO ===" >> "$report_file"
total_space=$(du -sh "$BACKUP_ROOT" 2>/dev/null | cut -f1)
echo "Spazio totale utilizzato: $total_space" >> "$report_file"
echo "" >> "$report_file"

# Clienti presenti
echo "=== CLIENTI PRESENTI ===" >> "$report_file"
client_count=0
for client_dir in "$BACKUP_ROOT"/*/; do
    if [ -d "$client_dir" ]; then
        client_count=$((client_count + 1))
        client=$(basename "$client_dir")
        client_size=$(du -sh "$client_dir" 2>/dev/null | cut -f1)
        file_count=$(find "$client_dir" -type f | wc -l)
        echo "$client: $client_size ($file_count file)" >> "$report_file"
    fi
done
echo "Totale clienti: $client_count" >> "$report_file"
echo "" >> "$report_file"

# Errori recenti dal log
if [ -f "$LOG_SOURCE" ]; then
    echo "=== ERRORI RECENTI (ultime 24h) ===" >> "$report_file"
    recent_errors=$(grep "❌ ERROR" "$LOG_SOURCE" | grep "$(date -d '24 hours ago' '+%Y/%m/%d')" || true)
    
    if [ -n "$recent_errors" ]; then
        echo "$recent_errors" >> "$report_file"
    else
        echo "Nessun errore rilevato nelle ultime 24 ore" >> "$report_file"
    fi
    echo "" >> "$report_file"
fi

# Statistiche cleanup
echo "=== STATISTICHE CLEANUP ===" >> "$report_file"
cleanup_lines=$(wc -l < "$CLEANUP_LOG" 2>/dev/null || echo "0")
echo "Operazioni di cleanup registrate: $cleanup_lines" >> "$report_file"
echo "" >> "$report_file"

# Avvisi
echo "=== AVVISI ===" >> "$report_file"
if [ "$disk_usage" -gt 80 ]; then
    echo "⚠️  ATTENZIONE: Utilizzo disco critico ($disk_usage%)" >> "$report_file"
fi

if grep -q "ATTENZIONE" "$CLEANUP_LOG"; then
    echo "⚠️  Sono stati rilevati problemi durante il cleanup" >> "$report_file"
fi

echo "" >> "$report_file"
echo "=== FINE REPORT ===" >> "$report_file"

echo "Report generato: $report_file"
log_cleanup "Report generato: $report_file"

# FASE 10: Aggiornamento audit_clean.log
echo ""
echo "FASE 10: Aggiornamento log di sistema"
timestamp=$(date '+%Y/%m/%d %H:%M:%S')
pid=$$
summary_line="Sistema/Interno              | $pid  | Sistema/Interno              | ---          | cleanup/automated_maintenance               | ✅ CLEANUP_COMPLETE"

echo "$summary_line" >> "$LOG_SOURCE"
log_cleanup "Riga di riepilogo aggiunta a audit_clean.log"

# Conteggio finale
files_removed=$(grep -c "Rimosso" "$CLEANUP_LOG" || echo "0")
space_freed="N/A"  # Potrebbe essere calcolato più precisamente

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