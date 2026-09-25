#!/usr/bin/env python3

import sys
import os

def calculate_averages(filename):
    """
    Read numbers from a text file and calculate incremental and normal averages.
    Each line should contain one number.
    """
    
    # Check if file exists
    if not os.path.exists(filename):
        print(f"Error: File '{filename}' not found.")
        return
    
    numbers = []
    
    # Read numbers from file
    try:
        with open(filename, 'r') as file:
            for line_num, line in enumerate(file, 1):
                line = line.strip()
                if line:  # Skip empty lines
                    try:
                        number = float(line)
                        numbers.append(number)
                    except ValueError:
                        print(f"Warning: Line {line_num} contains invalid number: '{line}'")
                        continue
    except Exception as e:
        print(f"Error reading file: {e}")
        return
    
    if not numbers:
        print("No valid numbers found in the file.")
        return
    
    # Display original numbers
    print("Original numbers:")
    for i, num in enumerate(numbers, 1):
        print(f"{i:3d}. {num:>12,.2f}")
    
    print("\n" + "="*60)
    print("INCREMENTAL AVERAGE CALCULATION")
    print("="*60)

    #Calculate mean avg
    mean_avg = sum(numbers) / len(numbers)
   
    
    # Calculate incremental averages
    running_sum = 0
    incremental_averages = []
    
    for i, num in enumerate(numbers, 1):
        running_sum += num
        average = running_sum / i
        incremental_averages.append(average)
        
        print(f"After {i:3d} numbers: Sum = {running_sum:>15,.2f}, Average = {average:>12,.2f}")
    
    print("\n" + "="*60)
    print("SUMMARY")
    print("="*60)
    print(f"Total count: {len(numbers)}")
    print(f"Final sum: {running_sum:,.2f}")
    print(f"Final average (normal): {running_sum/len(numbers):,.2f}")
    
    # Return the results for potential further use
    return {
        'numbers': numbers,
        'incremental_averages': incremental_averages,
        'final_average': running_sum / len(numbers),
        'mean_average': mean_avg,
        'total_sum': running_sum,
        'count': len(numbers)
    }

def main():
    if len(sys.argv) != 2:
        print("Usage: python3 calculate_averages.py <filename>")
        print("Example: python3 calculate_averages.py numbers.txt")
        sys.exit(1)
    
    filename = sys.argv[1]
    calculate_averages(filename)

if __name__ == "__main__":
    main() 