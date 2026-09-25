#!/bin/bash

# File path
file_path="/root/timestamp.txt"

timeout=100
start_time=$(date +%s)
while [ -z "$output" ]; do
    output=$(systemd-analyze)
    current_time=$(date +%s)
    elapsed_time=$((current_time - start_time))

    # Check if the output is empty or if the timeout is reached
    if [ -z "$output" ] && [ "$elapsed_time" -lt "$timeout" ]; then
        # Sleep for a short interval before checking again
        sleep 2
    else
        break
    fi
done

if [ -z "$output" ]; then
    echo "Timeout reached. systemd-analyze output is still empty." >> "$file_path"
    exit 1
fi

# Headers
headers=("kernel" "initrd" "userspace" "total" "multi-user")

# Maximum length of headers
max_length=0
for header in "${headers[@]}"; do
    if [ ${#header} -gt $max_length ]; then
        max_length=${#header}
    fi
done

# Print headers
for header in "${headers[@]}"; do
    printf "%-*s " $max_length "$header" >> "$file_path"
done

printf "\n" >> "$file_path"

# Append systemd-analyze data to the file
read -r kernel initrd userspace total multi_user_target < <(systemd-analyze | grep -oP '([0-9]+\.[0-9]+s|[0-9]+ms)' | tr '\n' ' ')

printf "%-*s %-*s %-*s %-*s %-*s\n" $max_length "$kernel" $max_length "$initrd" $max_length "$userspace" $max_length "$total" $max_length "$multi_user_target" >> "$file_path"

# Check for errors
if [ $? -ne 0 ]; then
    echo "Error in capturing systemd-analyze data"
    exit 1
fi

echo "Data successfully written to $file_path"
