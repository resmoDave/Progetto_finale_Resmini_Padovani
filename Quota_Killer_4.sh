#!/bin/bash

AUDIT_LOG="audit_clean.log"
LOG_KILLER="quota_killer.log"
MAX_QUOTA=1048576 

# Use tail -Fn0 to only read NEW lines added after the script starts
tail -Fn0 "$AUDIT_LOG" | while read -r line; do
    
    # 1. Parse using bash string manipulation (safer than awk here)
    # expected format: DATE TIME | PID | HOST | SIZE | PATH | STATUS
    if [[ "$line" == *"IN_PROGRESS"* ]]; then
        
        # Extract fields using pure bash to avoid regex issues
        PID=$(echo "$line" | awk -F ' *\\| *' '{print $2}')
        HOST_RAW=$(echo "$line" | awk -F ' *\\| *' '{print $3}')
        SIZE=$(echo "$line" | awk -F ' *\\| *' '{print $4}')
        HOST_ID=$(echo "$HOST_RAW" | grep -oP '(?<=srv-)[^)]+' | tr -d ')')
        
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