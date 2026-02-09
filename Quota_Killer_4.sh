#!/bin/bash

AUDIT_LOG="audit_clean.log"
LOG_KILLER="quota_killer.log"
MAX_QUOTA=1048576 

# ==============================================================================
# NEW FEATURE: Manual PID Kill Mode
# Usage: ./script.sh <PID>
# ==============================================================================
if [[ -n "$1" ]]; then
    TARGET_PID="$1"

    # 1. Validate input (ensure it is a number)
    if ! [[ "$TARGET_PID" =~ ^[0-9]+$ ]]; then
        echo "Error: '$TARGET_PID' is not a valid PID number."
        exit 1
    fi

    # 2. Check if the process exists
    if ps -p "$TARGET_PID" > /dev/null; then
        kill -9 "$TARGET_PID"
        echo "$(date) | Manually Killed PID $TARGET_PID - Argument trigger" >> "$LOG_KILLER"
        echo "Successfully killed PID $TARGET_PID."
    else
        echo "PID $TARGET_PID not found (already finished or invalid)."
    fi

    # Exit the script here so we don't start the monitoring loop
    exit 0
fi

# ==============================================================================
# EXISTING FEATURE: Monitor Audit Log
# ==============================================================================
echo "Starting audit log monitor..."

# Use tail -Fn0 to only read NEW lines added after the script starts
tail -Fn0 "$AUDIT_LOG" | while read -r line; do
    
    # expected format: DATE TIME | PID | HOST | SIZE | PATH | STATUS
    if [[ "$line" == *"IN_PROGRESS"* ]]; then
        
        # Extract fields using pure bash to avoid regex issues
        PID=$(echo "$line" | awk -F ' *\\| *' '{print $2}')
        HOST_RAW=$(echo "$line" | awk -F ' *\\| *' '{print $3}')
        SIZE=$(echo "$line" | awk -F ' *\\| *' '{print $4}')
        HOST_ID=$(echo "$HOST_RAW" | grep -oP '(?<=srv-)[^)]+' | tr -d ')')
        
        # Ensure SIZE is treated as a number for comparison
        # (Awk extraction might leave whitespace, bash handles arithmetic expansion automatically)
        if (( SIZE > MAX_QUOTA )); then
            # Check if the process is actually running!
            if ps -p "$PID" > /dev/null; then
                kill -9 "$PID"
                echo "$(date) | Killed active PID $PID ($HOST_ID) - Request size $SIZE > $MAX_QUOTA" >> "$LOG_KILLER"
            else
                echo "$(date) | PID $PID not found (already finished?)" >> "$LOG_KILLER"
            fi
        fi
    fi
done