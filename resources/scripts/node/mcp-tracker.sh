#!/bin/bash

# Simple MCP Worker Upgrade Tracker with Logging

LOG_FILE="mcp-upgrade.log"

echo "==================================="
echo "MCP Worker Upgrade Tracker"
echo "==================================="
echo ""

# Get start time (when Updating became True)
START_TIME=$(oc get mcp worker -o jsonpath='{.status.conditions[?(@.type=="Updating")].lastTransitionTime}')
echo "Start Time: $START_TIME"

# Get current progress
TOTAL=$(oc get mcp worker -o jsonpath='{.status.machineCount}')
UPDATED=$(oc get mcp worker -o jsonpath='{.status.updatedMachineCount}')
READY=$(oc get mcp worker -o jsonpath='{.status.readyMachineCount}')
DEGRADED=$(oc get mcp worker -o jsonpath='{.status.degradedMachineCount}')

echo ""
echo "Progress:"
echo "  Total Nodes:    $TOTAL"
echo "  Updated:        $UPDATED"
echo "  Ready:          $READY"
echo "  Degraded:       $DEGRADED"
echo "  Remaining:      $((TOTAL - UPDATED))"
echo ""

# Calculate percentage
PERCENT=$((UPDATED * 100 / TOTAL))
echo "Completion: $PERCENT% ($UPDATED/$TOTAL)"

# Show status
STATUS=$(oc get mcp worker -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}')
UPDATED_STATUS=$(oc get mcp worker -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}')

if [ "$STATUS" == "True" ]; then
    echo "Status: UPDATING ⏳"
    
    # Calculate elapsed time
    if command -v date &> /dev/null; then
        START_EPOCH=$(date -d "$START_TIME" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$START_TIME" +%s 2>/dev/null)
        CURRENT_EPOCH=$(date +%s)
        ELAPSED=$((CURRENT_EPOCH - START_EPOCH))
        HOURS=$((ELAPSED / 3600))
        MINUTES=$(((ELAPSED % 3600) / 60))
        echo "Elapsed Time: ${HOURS}h ${MINUTES}m"
        
        # Estimate remaining time
        if [ $UPDATED -gt 0 ]; then
            TIME_PER_NODE=$((ELAPSED / UPDATED))
            REMAINING_NODES=$((TOTAL - UPDATED))
            EST_REMAINING=$((TIME_PER_NODE * REMAINING_NODES))
            EST_HOURS=$((EST_REMAINING / 3600))
            EST_MINUTES=$(((EST_REMAINING % 3600) / 60))
            echo "Est. Remaining: ${EST_HOURS}h ${EST_MINUTES}m"
        fi
    fi
else
    echo "Status: COMPLETED ✅"
    END_TIME=$(oc get mcp worker -o jsonpath='{.status.conditions[?(@.type=="Updated")].lastTransitionTime}')
    echo "End Time: $END_TIME"
    
    # Log completion if not already logged
    if ! grep -q "COMPLETED at $END_TIME" "$LOG_FILE" 2>/dev/null; then
        echo "[$(date)] UPGRADE COMPLETED" >> "$LOG_FILE"
        echo "  Start Time:  $START_TIME" >> "$LOG_FILE"
        echo "  End Time:    $END_TIME" >> "$LOG_FILE"
        echo "  Total Nodes: $TOTAL" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
    fi
fi

# Log current status
echo "[$(date)] Progress: $UPDATED/$TOTAL ($PERCENT%) - Status: $STATUS" >> "$LOG_FILE"

echo ""
echo "==================================="
echo "Log file: $LOG_FILE"
