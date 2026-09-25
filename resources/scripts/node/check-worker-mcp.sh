#!/bin/bash

# check-mcp-worker.sh

while true; do
    UPDATED=$(oc get mcp worker -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}')
    UPDATING=$(oc get mcp worker -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}')
    DEGRADED=$(oc get mcp worker -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}')
    
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$TIMESTAMP] Worker MCP Status: UPDATED=$UPDATED, UPDATING=$UPDATING, DEGRADED=$DEGRADED"
    
    if [[ "$UPDATED" == "True" && "$UPDATING" == "False" && "$DEGRADED" == "False" ]]; then
        echo "✓ Worker MCP is fully updated and healthy!, timestamp: $TIMESTAMP"
        sleep 60
        oc apply -f descheduler-instance.yaml
    fi
    
    sleep 60
done