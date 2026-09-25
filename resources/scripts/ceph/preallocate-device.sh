#!/bin/bash
# Disk Pre-allocation Script
# This script writes zeros to a block device in parallel, creating one dd process
# for every 100GB of disk space

# Check if we have a block device specified
if [ $# -lt 1 ]; then
    echo "Usage: $0 <block-device>"
    echo "Example: $0 /dev/vdb"
    exit 1
fi

DEVICE=$1

# Check if the device exists
if [ ! -b "$DEVICE" ]; then
    echo "Error: $DEVICE is not a block device or does not exist."
    exit 1
fi

# Get the size of the disk in bytes
DISK_SIZE_BYTES=$(blockdev --getsize64 "$DEVICE")
echo "Disk size: $DISK_SIZE_BYTES bytes"

# Convert to GB for display (divide by 1024^3)
DISK_SIZE_GB=$(echo "scale=2; $DISK_SIZE_BYTES / 1073741824" | bc)
echo "Disk size: $DISK_SIZE_GB GB"

# Each chunk will be 100GB (in bytes)
CHUNK_SIZE=$((100 * 1024 * 1024 * 1024)) # 100GB in bytes

# Calculate the number of chunks
NUM_CHUNKS=$(($DISK_SIZE_BYTES / $CHUNK_SIZE))
if [ $(($DISK_SIZE_BYTES % $CHUNK_SIZE)) -ne 0 ]; then
    NUM_CHUNKS=$(($NUM_CHUNKS + 1))
fi

echo "Will create $NUM_CHUNKS dd processes to write zeros in parallel"
echo "Press Ctrl+C to abort or Enter to continue..."
read

# Array to store process IDs
declare -a PIDS

# Start time for performance tracking
START_TIME=$(date +%s)

# Start one dd process for each chunk
for ((i=0; i<$NUM_CHUNKS; i++)); do
    OFFSET=$(($i * $CHUNK_SIZE))
    
    # Calculate how many blocks to write for this chunk
    # If this is the last chunk, it might be smaller
    if [ $i -eq $(($NUM_CHUNKS - 1)) ] && [ $(($DISK_SIZE_BYTES % $CHUNK_SIZE)) -ne 0 ]; then
        REMAINING_BYTES=$(($DISK_SIZE_BYTES - $OFFSET))
        BLOCKS=$(($REMAINING_BYTES / 1024)) # dd uses 1KB blocks by default with bs=1K
    else
        BLOCKS=$(($CHUNK_SIZE / 1024))      # 100GB in KB
    fi
    
    # Calculate position in GB for logging
    OFFSET_GB=$(echo "scale=2; $OFFSET / 1073741824" | bc)
    
    echo "Starting dd process $((i+1))/$NUM_CHUNKS at offset ${OFFSET_GB}GB..."
    dd if=/dev/zero of=$DEVICE bs=1M seek=$(($OFFSET / 1024 / 1024)) count=$(($BLOCKS / 1024)) conv=notrunc oflag=direct status=progress &
    PIDS[$i]=$!
done

echo "All dd processes started. Waiting for completion..."

# Wait for all processes to complete
for pid in "${PIDS[@]}"; do
    wait $pid
    STATUS=$?
    if [ $STATUS -ne 0 ]; then
        echo "Warning: dd process with PID $pid exited with status $STATUS"
    fi
done

# Calculate elapsed time
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
HOURS=$((ELAPSED / 3600))
MINUTES=$(((ELAPSED % 3600) / 60))
SECONDS=$((ELAPSED % 60))

echo "All dd processes completed."
echo "Total time: $HOURS hours, $MINUTES minutes, $SECONDS seconds"
echo "Device $DEVICE has been pre-allocated with zeros"
