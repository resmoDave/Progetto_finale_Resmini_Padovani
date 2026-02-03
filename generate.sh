#!/bin/bash

# --- CONFIGURAZIONE ---
LOG_FILE="rsync_master.log"
SRC="./source_chaos"
DEST="./dest_chaos"
ITERAZIONI=100

# Server
WEB_SERVERS=("srv-web-01" "srv-web-02" "srv-web-03" "srv-web-04" "srv-web-05")
DB_SERVERS=("srv-db-01" "srv-db-02" "srv-db-03")
ALL_SERVERS=("${WEB_SERVERS[@]}" "${DB_SERVERS[@]}")

# Pulizia ambiente
rm -rf $SRC $DEST $LOG_FILE
mkdir -p $DEST

# Generazione IP fissi
declare -A HOST_IPS
for s in "${ALL_SERVERS[@]}"; do
    HOST_IPS[$s]="$((RANDOM%256)).$((RANDOM%256)).$((RANDOM%256)).$((RANDOM%256))"
done

echo "--- GENERAZIONE 100 LOG REALI CON IP PUBBLICI (BUG FIX) ---"

for ((i=1; i<=$ITERAZIONI; i++)); do
    SERVER=${ALL_SERVERS[$((RANDOM%8))]}
    IP=${HOST_IPS[$SERVER]}
    
    [[ $SERVER == srv-web* ]] && SIZE=$((RANDOM%5 + 1)) || SIZE=$((RANDOM%40 + 20))
    mkdir -p "$SRC/$SERVER"

    # --- FIX: Rimosso %t [%p] dal formato. Rsync li aggiunge da solo. ---
    LOG_FMT="$IP ($SERVER) %i %f %l"

    SCENARIO=$((RANDOM%10))
    case $SCENARIO in
        0|1) # Permission Denied
            FILE="secure_$i.bin"
            echo "lock" > "$SRC/$SERVER/$FILE"
            chmod 000 "$SRC/$SERVER/$FILE"
            rsync -av --log-file=$LOG_FILE --log-file-format="$LOG_FMT" "$SRC/$SERVER/" "$DEST/$SERVER/" 2>/dev/null
            chmod 644 "$SRC/$SERVER/$FILE"
            ;;
        2) # Connection Reset
            FILE="dump_$i.sql"
            dd if=/dev/urandom of="$SRC/$SERVER/$FILE" bs=1M count=$SIZE 2>/dev/null
            rsync -av --log-file=$LOG_FILE --log-file-format="$LOG_FMT" "$SRC/$SERVER/" "$DEST/$SERVER/" &
            RPID=$!
            sleep 0.1
            kill -9 $RPID 2>/dev/null
            # Scriviamo l'errore includendo solo le info che mancano
            echo "$(date +'%Y/%m/%d %H:%M:%S') [$RPID] $IP ($SERVER) rsync error: connection reset by peer (code 12)" >> $LOG_FILE
            ;;
        *) # Successo
            FILE="backup_$i.tar.gz"
            dd if=/dev/urandom of="$SRC/$SERVER/$FILE" bs=1M count=$SIZE 2>/dev/null
            rsync -av --log-file=$LOG_FILE --log-file-format="$LOG_FMT" "$SRC/$SERVER/" "$DEST/$SERVER/" > /dev/null
            ;;
    esac

    [ $((i % 20)) -eq 0 ] && echo "Processati $i backup..."
done

echo "------------------------------------------------"
echo "✅ LOG FINALE GENERATO CORRETTAMENTE"