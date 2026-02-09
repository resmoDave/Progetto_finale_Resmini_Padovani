#!/bin/bash

AUDIT_LOG="audit_clean.log"
LOG_KILLER="quota_killer.log"

# --- MODIFICATION START ---
# Use the first argument ($1) if provided; otherwise, default to 1048576
DEFAULT_QUOTA=1048576
MAX_QUOTA=${1:-$DEFAULT_QUOTA}

# Optional: Verify that MAX_QUOTA is a number
if ! [[ "$MAX_QUOTA" =~ ^[0-9]+$ ]]; then
    echo "Error: Quota must be a number."
    exit 1
fi

echo "Starting monitor... Using MAX_QUOTA: $MAX_QUOTA"
# --- MODIFICATION END ---

# Use tail -Fn0 to only read NEW lines added after the script starts
tail -Fn0 "$AUDIT_LOG" | while read -r line; do
    
    # 1. Check for IN_PROGRESS entries
    if [[ "$line" == *"IN_PROGRESS"* ]]; then
        
        # Extract fields using awk based on the | delimiter
        PID=$(echo "$line" | awk -F ' *\\| *' '{print $2}')
        HOST_RAW=$(echo "$line" | awk -F ' *\\| *' '{print $3}')
        SIZE=$(echo "$line" | awk -F ' *\\| *' '{print $4}')
        HOST_ID=$(echo "$HOST_RAW" | grep -oP '(?<=srv-)[^)]+' | tr -d ')')
        
        # 2. Compare against the quota
        if (( SIZE > MAX_QUOTA )); then
            # 3. CRITICAL: Check if the process is actually running!
            if ps -p "$PID" > /dev/null; then
                kill -9 "$PID"
                echo "$(date) | Killed active PID $PID ($HOST_ID) - Request size $SIZE > $MAX_QUOTA" >> "$LOG_KILLER"
            else
                echo "$(date) | PID $PID not found (already finished?)" >> "$LOG_KILLER"
            fi
        fi
    fi
done