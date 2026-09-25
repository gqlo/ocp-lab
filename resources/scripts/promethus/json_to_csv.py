#!/usr/bin/env python3
"""
Extract memory values from JSON files and output to CSV format.
Usage: python memory_extractor.py <json_file>
"""

import json
import sys
import csv
import os

def extract_json_from_file(file_path):
    """Extract JSON data from a file that contains additional text and JSON."""
    with open(file_path, 'r') as f:
        content = f.read()
    
    # Find the JSON part by looking for opening and closing braces
    lines = content.split('\n')
    json_start_idx = -1
    json_end_idx = -1
    
    # Find where JSON starts
    for i, line in enumerate(lines):
        if line.strip() == '{':
            json_start_idx = i
            break
    
    if json_start_idx == -1:
        raise ValueError("No JSON object found in file")
    
    # Find where JSON ends by counting braces
    brace_count = 0
    for i in range(json_start_idx, len(lines)):
        line = lines[i]
        for char in line:
            if char == '{':
                brace_count += 1
            elif char == '}':
                brace_count -= 1
        
        if brace_count == 0:
            json_end_idx = i
            break
    
    if json_end_idx == -1:
        raise ValueError("Invalid JSON structure - no closing brace found")
    
    # Extract and parse JSON
    json_text = '\n'.join(lines[json_start_idx:json_end_idx + 1])
    return json.loads(json_text)

def extract_memory_values(json_data):
    """Extract timestamp and memory values from parsed JSON data."""
    if (json_data.get('status') != 'success' or 
        not json_data.get('data', {}).get('result')):
        raise ValueError("Invalid JSON structure - no valid results found")
    
    result = json_data['data']['result'][0]
    values = result.get('values', [])
    
    if not values:
        raise ValueError("No values found in JSON data")
    
    # Extract timestamp, value pairs
    extracted_data = []
    for timestamp, memory_value in values:
        extracted_data.append([timestamp, memory_value])
    
    return extracted_data, result.get('metric', {})

def write_to_csv(data, metadata, output_file):
    """Write extracted data to CSV file."""
    with open(output_file, 'w', newline='') as csvfile:
        writer = csv.writer(csvfile)
        
        # Write header with metadata as comments
        writer.writerow(['# Extracted from memory monitoring data'])
        if metadata:
            writer.writerow([f'# Container: {metadata.get("container", "N/A")}'])
            writer.writerow([f'# Pod: {metadata.get("pod", "N/A")}'])
            writer.writerow([f'# Namespace: {metadata.get("namespace", "N/A")}'])
            writer.writerow([f'# Node: {metadata.get("node", "N/A")}'])
        
        # Write column headers
        writer.writerow(['timestamp', 'memory_bytes'])
        
        # Write data
        for row in data:
            writer.writerow(row)

def main():
    if len(sys.argv) != 2:
        print("Usage: python memory_extractor.py <json_file>")
        print("Example: python memory_extractor.py mem_raw.json")
        sys.exit(1)
    
    input_file = sys.argv[1]
    
    if not os.path.exists(input_file):
        print(f"Error: File '{input_file}' not found")
        sys.exit(1)
    
    try:
        # Extract JSON data
        print(f"Processing {input_file}...")
        json_data = extract_json_from_file(input_file)
        
        # Extract memory values
        memory_data, metadata = extract_memory_values(json_data)
        
        # Generate output filename
        base_name = os.path.splitext(input_file)[0]
        output_file = f"{base_name}_data.csv"
        
        # Write to CSV
        write_to_csv(memory_data, metadata, output_file)
        
        print(f"Successfully extracted {len(memory_data)} data points")
        print(f"Output saved to: {output_file}")
        
        # Display some stats
        if metadata:
            print(f"Container: {metadata.get('container', 'N/A')}")
            print(f"Pod: {metadata.get('pod', 'N/A')}")
            print(f"Namespace: {metadata.get('namespace', 'N/A')}")
        
        if memory_data:
            memory_values = [float(row[1]) for row in memory_data]
            print(f"Memory range: {min(memory_values):.0f} - {max(memory_values):.0f} bytes")
            print(f"Memory range: {min(memory_values)/1024/1024:.1f} - {max(memory_values)/1024/1024:.1f} MB")
    
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
