#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# File path
file_path="/root/timestamp.txt"

sudo rm -f "$file_path"

touch "$file_path"

# Check for errors
if [ $? -ne 0 ]; then
    echo "Error in creating file"
    exit 1
fi

# Write the timestamp and date to the file
current_date=$(date '+%s, %Y-%m-%d %T')
echo "unix-timestamp, date" > "$file_path"
echo "$current_date" >> "$file_path"

# Check for errors
if [ $? -ne 0 ]; then
    echo "Error in capturing time stamp data"
    exit 1
fi

echo "Data successfully written to $file_path"
