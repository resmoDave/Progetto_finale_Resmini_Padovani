#!/bin/bash

# --- CONFIGURATION ---
LOG_FILE="$(pwd)/rsync_master.log"
MOCK_CLIENTS_DIR="$(pwd)/remote_storage"
LOCAL_BACKUP_DIR="$(pwd)/local_backup"
RSYNC_CONF="$(pwd)/rsyncd.conf"
PORT=9876
ITERAZIONI=100

# Cleanup
rm -rf "$MOCK_CLIENTS_DIR" "$LOCAL_BACKUP_DIR" "$LOG_FILE" "$RSYNC_CONF"
mkdir -p "$MOCK_CLIENTS_DIR" "$LOCAL_BACKUP_DIR"

# 1. CREATE MOCK RSYNC DAEMON CONFIG
# This allows us to "pull" from localhost as if it were a remote client
cat <<EOF > "$RSYNC_CONF"
port = $PORT
use chroot = no
[clients]
    path = $MOCK_CLIENTS_DIR
    read only = yes
    list = yes
EOF

# 2. START THE DAEMON (Running in background)
rsync --daemon --config="$RSYNC_CONF" --address=127.0.0.1
trap "fuser -k $PORT/tcp; rm $RSYNC_CONF" EXIT

# Server/IP Mapping
ALL_CLIENTS=("srv-web-01" "srv-web-02" "srv-web-03" "srv-web-04" "srv-web-05" "srv-db-01" "srv-db-02" "srv-db-03")
declare -A HOST_IPS
for s in "${ALL_CLIENTS[@]}"; do
    HOST_IPS[$s]="$((RANDOM%256)).$((RANDOM%256)).$((RANDOM%256)).$((RANDOM%256))"
done

echo "--- GENERATING AUTHENTIC PULL LOGS (DAEMON MODE) ---"

for ((i=1; i<=$ITERAZIONI; i++)); do
    CLIENT=${ALL_CLIENTS[$((RANDOM%8))]}
    IP=${HOST_IPS[$CLIENT]}
    [[ $CLIENT == srv-web* ]] && SIZE=$((RANDOM%5 + 1)) || SIZE=$((RANDOM%40 + 20))

    # Create file on the "Remote" side
    mkdir -p "$MOCK_CLIENTS_DIR/$CLIENT"
    FILE="backup_$i.dat"
    dd if=/dev/urandom of="$MOCK_CLIENTS_DIR/$CLIENT/$FILE" bs=1M count=$SIZE 2>/dev/null

    # THE MAGIC: PULLING from the daemon
    # Log format: %i will show ">" (received) and summary will show "received [BIG]"
    # We use --out-format to ensure the log file gets the specific IP and Hostname
    LOG_FMT="$IP ($CLIENT) %i %f %l"

    SCENARIO=$((RANDOM%10))
    case $SCENARIO in
        0) # Permission Error
            chmod 000 "$MOCK_CLIENTS_DIR/$CLIENT/$FILE"
            rsync -av --log-file="$LOG_FILE" --log-file-format="$LOG_FMT" \
                rsync://127.0.0.1:$PORT/clients/$CLIENT/ "$LOCAL_BACKUP_DIR/$CLIENT/" 2>/dev/null
            chmod 644 "$MOCK_CLIENTS_DIR/$CLIENT/$FILE"
            ;;
        1) # Connection Reset / Kill
            rsync -av --log-file="$LOG_FILE" --log-file-format="$LOG_FMT" \
                rsync://127.0.0.1:$PORT/clients/$CLIENT/ "$LOCAL_BACKUP_DIR/$CLIENT/" &
            RPID=$!
            sleep 0.01
            kill -9 $RPID 2>/dev/null
            echo "$(date +'%Y/%m/%d %H:%M:%S') [$RPID] $IP ($CLIENT) rsync error: connection reset by peer (code 12)" >> "$LOG_FILE"
            ;;
        *) # Successful Pull
            rsync -av --log-file="$LOG_FILE" --log-file-format="$LOG_FMT" \
                rsync://127.0.0.1:$PORT/clients/$CLIENT/ "$LOCAL_BACKUP_DIR/$CLIENT/" > /dev/null
            ;;
    esac

    [ $((i % 20)) -eq 0 ] && echo "Pulling $i/100 completed..."
done

echo "------------------------------------------------"
echo "✅ DONE. Check the log: $LOG_FILE"
echo "Example of a successful pull line from your log:"
tail -n 1 "$LOG_FILE"