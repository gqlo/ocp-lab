#!/bin/bash

# Script to monitor and patch subscription resource values
# Checks every 5 seconds and patches if values are changed

set -eu

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Subscription configurations - using functions to avoid quote escaping issues
get_patch_json_1() {
    echo '{"spec":{"config":{"resources":{"limits":{"memory":"4Gi","cpu":"1000m"},"requests":{"memory":"4Gi","cpu":"10m"}}}}}'
}

get_patch_json_2() {
    echo '{"spec":{"config":{"resources":{"limits":{"memory":"100Gi","cpu":"20"},"requests":{"memory":"4Gi","cpu":"500m"}}}}}'
}

SUBS=(
    "odf-csi-addons-operator-stable-4.19-redhat-operators-openshift-marketplace|get_patch_json_1"
    "ocs-client-operator-stable-4.19-redhat-operators-openshift-marketplace|get_patch_json_2"
)

NAMESPACE="openshift-storage"
CHECK_INTERVAL=5
LOGFILE="${LOGFILE:-monitor-patch-subscriptions.log}"

# Check if oc command exists
if ! command -v oc &> /dev/null; then
    echo -e "${RED}Error: oc command not found${NC}" >&2
    exit 1
fi

echo "Starting subscription resource monitor..."
echo "Checking every ${CHECK_INTERVAL} seconds"
echo "Log file: $LOGFILE"
echo "Press Ctrl+C to stop"
echo ""

# Initialize log file
touch "$LOGFILE"

while true; do
    for sub_config in "${SUBS[@]}"; do
        IFS='|' read -r sub_name patch_json_func <<< "$sub_config"
        
        # Get JSON from function
        patch_json=$($patch_json_func)
        
        # Validate JSON before using
        if ! echo "$patch_json" | jq . >/dev/null 2>&1; then
            echo -e "${RED}Error: Invalid JSON for subscription $sub_name${NC}" >&2
            continue
        fi
        
        # Get current subscription config and normalize it
        current_config=$(oc get subscriptions.operators.coreos.com "$sub_name" -n "$NAMESPACE" -o json 2>/dev/null | jq -c -S '.spec.config.resources // {}' 2>/dev/null || echo "{}")
        desired_config=$(echo "$patch_json" | jq -c -S '.spec.config.resources')
        
        # Compare current vs desired using jq for proper JSON deep equality check
        # Normalize both to handle key order differences
        current_normalized=$(echo "$current_config" | jq -c -S .)
        desired_normalized=$(echo "$desired_config" | jq -c -S .)
        
        if [ "$current_normalized" != "$desired_normalized" ]; then
            timestamp=$(date '+%Y-%m-%d %H:%M:%S')
            log_message="[$timestamp] Patching subscription: $sub_name"
            echo -e "${YELLOW}[$timestamp]${NC} Patching subscription: $sub_name"
            echo "$log_message" >> "$LOGFILE"
            patch_output=$(oc patch subscriptions.operators.coreos.com "$sub_name" -n "$NAMESPACE" -p "$patch_json" --type merge 2>&1)
            patch_exit=$?
            timestamp=$(date '+%Y-%m-%d %H:%M:%S')
            if [ $patch_exit -eq 0 ]; then
                log_message="[$timestamp] ✓ Patched successfully: $sub_name"
                echo -e "${GREEN}[$timestamp] ✓ Patched successfully${NC}"
                echo "$log_message" >> "$LOGFILE"
            else
                log_message="[$timestamp] ✗ Failed to patch: $sub_name"
                echo -e "${RED}[$timestamp] ✗ Failed to patch${NC}"
                echo "$log_message" >> "$LOGFILE"
                error_output=$(echo "$patch_output" | sed 's/^/    /')
                echo "$error_output"
                echo "$error_output" >> "$LOGFILE"
            fi
        else
            log_message="[$(date '+%Y-%m-%d %H:%M:%S')] No change detected for subscription: $sub_name"
            echo "$log_message" >> "$LOGFILE"
        fi
    done
    
    sleep "$CHECK_INTERVAL"
done

