#!/bin/bash

# Script to extract phase transition timestamps from all VirtualMachineInstanceMigrations
# Usage: ./extract-phase-timestamp.sh <phase-filter> [namespace]

set -eu

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

fatal() {
    echo -e "${RED}Error:${NC} $*" >&2
    exit 1
}

help() {
    cat <<EOF
Usage: $0 <phase-filter> [namespace]

Extract all phase transition timestamps from VirtualMachineInstanceMigration objects
filtered by the specified phase.

Arguments:
    phase-filter   Phase to filter by (e.g., "Failed", "Succeeded", "Running", "Pending")
    namespace      (Optional) Namespace to search in. If not provided, searches all namespaces.

Examples:
    $0 Failed
    $0 Succeeded vm-ns-9
    $0 Running
    $0 Pending

EOF
}

# Function to extract and display timestamps for a single VMIM
extract_vmim_timestamps() {
    local vmim_name=$1
    local namespace=$2
    
    # Get VMIM object in JSON format
    local vmim_json
    vmim_json=$(oc get vmim "$vmim_name" -n "$namespace" -o json 2>/dev/null) || {
        echo -e "${YELLOW}Warning:${NC} Failed to get VMIM '$vmim_name' in namespace '$namespace'" >&2
        return 1
    }
    
    # Extract phase transition timestamps
    local phases
    phases=$(echo "$vmim_json" | jq -r '.status.phaseTransitionTimestamps[]? | "\(.phase)|\(.phaseTransitionTimestamp)"')
    
    if [ -z "$phases" ]; then
        echo -e "${YELLOW}  No phase transition timestamps found${NC}"
        return 0
    fi
    
    # Display VMIM header
    echo -e "${BLUE}VMIM: $vmim_name${NC} (Namespace: $namespace)"
    echo "  Phase Transition Timestamps:"
    
    # Count phases and calculate durations
    local prev_timestamp=""
    local phase_count=0
    
    while IFS='|' read -r phase timestamp; do
        phase_count=$((phase_count + 1))
        
        if [ -n "$timestamp" ]; then
            # Convert ISO 8601 timestamp to readable format
            local readable_time
            readable_time=$(date -d "$timestamp" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$timestamp")
            
            echo -e "    ${GREEN}Phase $phase_count:${NC} $phase"
            echo "      Timestamp: $timestamp"
            echo "      Readable:  $readable_time"
            
            # Calculate duration from previous phase if available
            if [ -n "$prev_timestamp" ]; then
                # Convert timestamps to seconds since epoch for calculation
                local prev_epoch curr_epoch
                prev_epoch=$(date -d "$prev_timestamp" +%s 2>/dev/null)
                curr_epoch=$(date -d "$timestamp" +%s 2>/dev/null)
                
                if [ -n "$prev_epoch" ] && [ -n "$curr_epoch" ]; then
                    local duration duration_hours duration_mins duration_secs
                    duration=$((curr_epoch - prev_epoch))
                    duration_hours=$((duration / 3600))
                    duration_mins=$(((duration % 3600) / 60))
                    duration_secs=$((duration % 60))
                    
                    if [ $duration_hours -gt 0 ]; then
                        echo "      Duration:  ${duration_hours}h ${duration_mins}m ${duration_secs}s (from previous phase)"
                    elif [ $duration_mins -gt 0 ]; then
                        echo "      Duration:  ${duration_mins}m ${duration_secs}s (from previous phase)"
                    else
                        echo "      Duration:  ${duration_secs}s (from previous phase)"
                    fi
                fi
            fi
            
            prev_timestamp="$timestamp"
        fi
    done <<< "$phases"
    
    # Calculate total duration if we have at least 2 phases
    if [ $phase_count -ge 2 ]; then
        local first_timestamp last_timestamp
        first_timestamp=$(echo "$phases" | head -1 | cut -d'|' -f2)
        last_timestamp=$(echo "$phases" | tail -1 | cut -d'|' -f2)
        
        local first_epoch last_epoch
        first_epoch=$(date -d "$first_timestamp" +%s 2>/dev/null)
        last_epoch=$(date -d "$last_timestamp" +%s 2>/dev/null)
        
        if [ -n "$first_epoch" ] && [ -n "$last_epoch" ]; then
            local total_duration total_hours total_mins total_secs
            total_duration=$((last_epoch - first_epoch))
            total_hours=$((total_duration / 3600))
            total_mins=$(((total_duration % 3600) / 60))
            total_secs=$((total_duration % 60))
            
            echo "    Total Duration:"
            if [ $total_hours -gt 0 ]; then
                echo "      ${total_hours}h ${total_mins}m ${total_secs}s"
            elif [ $total_mins -gt 0 ]; then
                echo "      ${total_mins}m ${total_secs}s"
            else
                echo "      ${total_secs}s"
            fi
        fi
    fi
    
    echo "    Total Phases: $phase_count"
    echo ""
}

# Check if oc command exists
if ! command -v oc &> /dev/null; then
    fatal "oc command not found. Please install OpenShift CLI."
fi

# Check if jq command exists (for JSON parsing)
if ! command -v jq &> /dev/null; then
    fatal "jq command not found. Please install jq for JSON parsing."
fi

# Parse arguments
if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    help
    exit 0
fi

if [ $# -lt 1 ]; then
    fatal "Missing required phase filter. Use -h or --help for usage information."
fi

PHASE_FILTER=$1
NAMESPACE=${2:-""}

# Build oc command
if [ -n "$NAMESPACE" ]; then
    echo "Searching for VMIMs with phase '$PHASE_FILTER' in namespace: $NAMESPACE"
    VMIM_LIST=$(oc get vmim -n "$NAMESPACE" -o json 2>/dev/null) || {
        fatal "Failed to list VMIMs in namespace '$NAMESPACE'. Check your permissions."
    }
else
    echo "Searching for VMIMs with phase '$PHASE_FILTER' in all namespaces"
    VMIM_LIST=$(oc get vmim --all-namespaces -o json 2>/dev/null) || {
        fatal "Failed to list VMIMs. Check your permissions."
    }
fi

# Filter VMIMs by phase and extract name/namespace
MATCHING_VMIMS=$(echo "$VMIM_LIST" | jq -r --arg phase "$PHASE_FILTER" '
    .items[]? | 
    select(.status.phase == $phase) | 
    "\(.metadata.name)|\(.metadata.namespace)"
')

if [ -z "$MATCHING_VMIMS" ]; then
    echo -e "${YELLOW}No VMIMs found with phase '$PHASE_FILTER'${NC}"
    exit 0
fi

# Count matching VMIMs
VMIM_COUNT=$(echo "$MATCHING_VMIMS" | wc -l)
echo -e "${GREEN}Found $VMIM_COUNT VMIM(s) with phase '$PHASE_FILTER'${NC}"
echo "=================================="
echo ""

# Process each matching VMIM
VMIM_PROCESSED=0
while IFS='|' read -r vmim_name namespace; do
    if [ -n "$vmim_name" ] && [ -n "$namespace" ]; then
        extract_vmim_timestamps "$vmim_name" "$namespace"
        VMIM_PROCESSED=$((VMIM_PROCESSED + 1))
    fi
done <<< "$MATCHING_VMIMS"

echo "=================================="
echo -e "${GREEN}Processed $VMIM_PROCESSED VMIM(s)${NC}"

