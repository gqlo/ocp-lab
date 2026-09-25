#!/usr/bin/env python3

import sys
import os

def calculate_incremental_average_method1(numbers):
    """
    Method 1: Direct Update Formula
    NewAverage = OldAverage + (NewValue - OldAverage) / NewSampleCount
    """
    print("Method 1: NewAverage = OldAverage + (NewValue - OldAverage) / NewSampleCount")
    print("-" * 60)
    
    average = 0
    incremental_averages = []
    
    for i, num in enumerate(numbers, 1):
        if i == 1:
            average = num
        else:
            average = average + (num - average) / i
        incremental_averages.append(average)
        print(f"After {i:3d} numbers: Average = {average:>12,.2f}")
    
    return incremental_averages

def calculate_incremental_average_method2(numbers):
    """
    Method 2: Linear Interpolation Formula
    Average = mix(Average, NewValue, 1.0 / NewSampleCount)
    """
    print("\nMethod 2: Average = mix(Average, NewValue, 1.0 / NewSampleCount)")
    print("-" * 60)
    
    average = 0
    incremental_averages = []
    
    for i, num in enumerate(numbers, 1):
        if i == 1:
            average = num
        else:
            # mix(a, b, t) = a + (b-a)*t
            # where t = 1.0 / NewSampleCount
            t = 1.0 / i
            average = average + (num - average) * t
        incremental_averages.append(average)
        print(f"After {i:3d} numbers: Average = {average:>12,.2f}")
    
    return incremental_averages

def calculate_incremental_average_method3(numbers):
    """
    Method 3: Traditional Running Sum
    Average = (Sum of all values) / Count
    """
    print("\nMethod 3: Traditional Running Sum (current implementation)")
    print("-" * 60)
    
    running_sum = 0
    incremental_averages = []
    
    for i, num in enumerate(numbers, 1):
        running_sum += num
        average = running_sum / i
        incremental_averages.append(average)
        print(f"After {i:3d} numbers: Average = {average:>12,.2f}")
    
    return incremental_averages

def calculate_all_incremental_averages(numbers):
    """
    Calculate incremental averages using all three methods
    """
    print("="*80)
    print("INCREMENTAL AVERAGE CALCULATION - ALL THREE METHODS")
    print("="*80)
    
    # Calculate using all three methods
    method1_results = calculate_incremental_average_method1(numbers)
    method2_results = calculate_incremental_average_method2(numbers)
    method3_results = calculate_incremental_average_method3(numbers)
    
    return {
        'method1': method1_results,
        'method2': method2_results,
        'method3': method3_results
    }

def compare_methods(results):
    """
    Compare the results of all three methods
    """
    print("\n" + "="*80)
    print("FINAL COMPARISON")
    print("="*80)
    
    final_method1 = results['method1'][-1]
    final_method2 = results['method2'][-1]
    final_method3 = results['method3'][-1]
    
    print(f"Method 1 (Direct Update):     {final_method1:>12,.2f}")
    print(f"Method 2 (Linear Interp):     {final_method2:>12,.2f}")
    print(f"Method 3 (Running Sum):       {final_method3:>12,.2f}")
    
    # Verify all methods give the same result
    if abs(final_method1 - final_method2) < 1e-10 and abs(final_method2 - final_method3) < 1e-10:
        print("\n✅ All three methods produce identical results!")
    else:
        print("\n❌ Methods produce different results!")
        print(f"Difference between Method 1 and 2: {abs(final_method1 - final_method2)}")
        print(f"Difference between Method 2 and 3: {abs(final_method2 - final_method3)}")
    
    print("\n" + "="*80)
    print("EXPLANATION")
    print("="*80)
    print("All three methods are mathematically equivalent:")
    print("1. Direct Update: NewAverage = OldAverage + (NewValue - OldAverage) / NewSampleCount")
    print("2. Linear Interpolation: Average = mix(Average, NewValue, 1.0 / NewSampleCount)")
    print("3. Running Sum: Average = (Sum of all values) / Count")
    print("\nThe demofox formulas (Methods 1 & 2) are more efficient for incremental updates as they")
    print("don't require storing the running sum - only the current average.")
    
    return {
        'method1_final': final_method1,
        'method2_final': final_method2,
        'method3_final': final_method3
    }

def read_numbers_from_file(filename):
    """
    Read numbers from a text file, one number per line
    """
    if not os.path.exists(filename):
        print(f"Error: File '{filename}' not found.")
        return None
    
    numbers = []
    
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
        return None
    
    if not numbers:
        print("No valid numbers found in the file.")
        return None
    
    return numbers

def main():
    # Check if filename is provided as command line argument
    if len(sys.argv) > 1:
        filename = sys.argv[1]
        numbers = read_numbers_from_file(filename)
        if numbers is None:
            sys.exit(1)
    else:
        # Use sample numbers if no file provided
        numbers = [
            41455616, 41459712, 41459712, 41459712, 39694336,
            39694336, 40103936, 40767488, 40763392, 40763392,
            41431040, 41435136, 41439232, 37556224, 38219776,
            40210432, 40312832, 40443904, 40448000, 40448000
        ]
        print("Using sample numbers (no file provided)")
        print("Usage: python3 incremental_average_comparison.py <filename>")
    
    print("\nOriginal numbers:")
    for i, num in enumerate(numbers, 1):
        print(f"{i:3d}. {num:>12,.2f}")
    
    # Calculate all methods
    results = calculate_all_incremental_averages(numbers)
    
    # Compare results
    final_results = compare_methods(results)
    
    # Return results for potential further use
    return final_results

if __name__ == "__main__":
    main() 