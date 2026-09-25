#!/usr/bin/env python3

import os
import re
import csv
import json
import glob
import sys
import argparse
import yaml
import subprocess
from datetime import datetime, timezone

# Python scripts process promethus JSON raw metrics

def sys_exit(str):
    print(f"{str}")
    sys.exit(1)

def is_dir(dir_path):
    if not os.path.isdir(dir_path):
        print(f"The directory '{dir_path}' does not exits")
        return False
    return True

def unix_time(date_str):
    """
    Convert a date string in format "YYYY-MM-DD HH:MM:SS" to Unix timestamp in UTC
    
    Args:
        date_str (str): Date string in format "YYYY-MM-DD HH:MM:SS"
        
    Returns:
        int: Unix timestamp in seconds
    """
    try:
        return int(datetime.fromisoformat(date_str).replace(tzinfo=timezone.utc).timestamp())
    except ValueError as e:
        return f"Error: {e}"

def file_is_readable(file_path):
    if not os.access(file_path, os.R_OK):
        print(f"The file at '{file_path}' is not readable")
        return False
    return True

def obj_exist(obj):
    return obj is not None

def check_meta_data(json_obj):
    status = json_obj.get("status")
    if obj_exist(status) and status == "success":
        print("Promethus query status returned success")
    else:
        sys_exit("Promethus query status returned non-success or status value is not present")
    data = json_obj.get("data")
    res_type = data.get("resultType")
    res = data.get("result")
    empty_metric = 0
    if obj_exist(data) and obj_exist(res_type) and obj_exist(res) and len(res) >= 1:
        for item in res:
            if len(item['metric']) == 0:
                empty_metric += 1
        print(f"total of {len(res)} entries of data found, {empty_metric} entires without metric name, resultType: {res_type}")
    else:
        sys_exit("No data found, please check your json file")

# read the path of json files with given directory
def read_json_files(dir_path):
    if is_dir(dir_path):
        return glob.glob(f"{dir_path}/*.json")

def read_csv_files(dir_path):
    if bool(re.match(r"^~", dir_path)):
        print(f"~ symbol found")
        dir_path = os.path.expanduser(dir_path)
    if is_dir(dir_path):
        print(f"globing path: {dir_path}")
        glob_obj = glob.glob(f"{dir_path}/*.csv")
        if len(glob_obj) < 1:
            sys_exit(f"no csv files found at {dir_path}")
        else:
            print(f"{len(glob_obj)} csv files found in total")
            return glob.glob(f"{dir_path}/*.csv")
    else:
        sys_exit(f"{dir_path} is not recognized as a directory")

def read_json_file(file_path):
    try:
        with open(file_path, "r") as file:
            return json.load(file)
    except FileNotFoundError:
        print(f"Error: file '{file_path}' does not exists")
    except IOError:
        print(f"Error: could not open file '{file_path}'")

def read_csv_file(file_path):
    try:
        return csv.reader(open(file_path, "r"))
    except FileNotFoundError:
        print(f"Error: file '{file_path}' does not exists")
    except IOError:
        print(f"Error: could not open file '{file_path}'")

# row expects an array
def csv_write_row(path, row):
    try:
        with open(path, mode='a', newline='') as file:
            writer = csv.writer(file)
            writer.writerow(row)
    except Exception as e:
        print(f"Error: '{e}' occured while writing data into '{path}'")


# structure a raw json object 
def process_raw_json_obj(json_obj):
    res = {}
    result = json_obj['data']["result"]
    for item in result:
        res[list(item['metric'].keys())[0]] = [float(value[1]) for value in item['values']]
    return res

def json_to_csv(file_path):
    if file_is_readable(file_path):
        json_obj = read_json_file(file_path)
    check_meta_data(json_obj)
    result = json_obj['data']["result"]
    csv_file_path=re.sub(r"\.json$", ".csv", file_path)
    filename = re.search(r'[^/\\]+(?=\.[^.]+$)', file_path).group(0)
    data_points = {}
    for item in result:
        if len(item['metric']) == 0:
            header = filename
        else:
            header = "".join([f"{key}_{value}" for key, value in item['metric'].items()])
    
        values = []
        values = [float(value[1]) for value in item['values']]
        non_zero_values = [value for value in values if value != float(0)]
        if len(non_zero_values) != len(values) or len(non_zero_values) == 0:
            print(f"found zero value: {header}, non-zero values/zero values count{len(values)}/{len(non_zero_values)}")
        data_points[header] = values
        
    headers = list(data_points.keys())
    csv_write_row(csv_file_path, headers)
    max_length = max(len(values) for values in data_points.values())
    for i in range(max_length):
        row = []
        for header in headers:
            values = data_points[header]
            row.append(values[i] if i < len(values) else "")
        csv_write_row(csv_file_path, row)
    print(f"csv file saved at {csv_file_path}")
    
def is_int(num):
    try:
        int(num)
        return True
    except ValueError:
        print("Error: expecting the time stamp to be an integer")
        return False

def validate_metric_profile(metric_profile):
    # Check if metric_profile has the required keys
    if 'metrics' not in metric_profile or 'global_config' not in metric_profile:
        print("Error: metric_profile is missing required 'metrics' or 'global_config' sections")
        return False
    # Validate each metric
    for i, metric in enumerate(metric_profile['metrics']):
        # Check that metric is a dictionary
        if not isinstance(metric, dict):
            print(f"Error: metric at index {i} is not a dictionary")
            return False
        # Check for missing parameters
        if metric.get('start') is None and metric_profile['global_config'].get('start') is None:
            print(f"Error: metric '{metric.get('name', f'at index {i}')}' is missing start timestamp")
            return False
        if metric.get('end') is None and metric_profile['global_config'].get('start') is None:
            print(f"Error: metric '{metric.get('name', f'at index {i}')}' is missing end timestamp")
            return False
        if metric.get('step') is None and metric_profile['global_config'].get('step') is None:
            print(f"Error: metric '{metric.get('name', f'at index {i}')}' is missing step interval")
            return False
        # Validate that query exists
        if 'query' not in metric or not metric['query']:
            print(f"Error: metric '{metric.get('name', f'at index {i}')}' is missing query expression")
            return False 
    return True

def curl_promethus_endpoint(query_name, start, end, step, query_expression, output_dir=None):
    print(f"executing query: {query_name}")
    urlencode_cmd = ["urlencode", query_expression]
    encoded_url = subprocess.run(urlencode_cmd, capture_output=True, text="True")
    encoded_expr = encoded_url.stdout.replace('\n', '').replace('\r', '')
    curl_cmd = (
            f"oc exec -n openshift-monitoring -c prometheus prometheus-k8s-1 -- "
            f"curl -s 'http://localhost:9090/api/v1/query_range?"
            f"query={encoded_expr}&start={start}&end={end}&step={step}'"
    )
    query_result = subprocess.run(curl_cmd, capture_output=True, shell=True, text=True)
    if query_result.returncode != 0:
        print(f"Error executing query: {query_result.stderr}")
        return False
    
    # Process the JSON output with jq and write to file on host
    jq_cmd = ["jq", "."]
    jq_process = subprocess.run(jq_cmd, input=query_result.stdout, capture_output=True, text=True)
    if jq_process.returncode != 0:
        print(f"Error processing JSON with jq: {jq_process.stderr}")
        return False
    
    # Determine output directory - use provided dir or current directory
    if output_dir is None:
        output_dir = os.getcwd()
    else:
        # Ensure output directory exists
        os.makedirs(output_dir, exist_ok=True)
    
    # Write the formatted JSON to file on the host
    json_file_path = os.path.join(output_dir, f"{query_name}.json")
    try:
        with open(json_file_path, 'w') as f:
            f.write(jq_process.stdout)
        print(f"extracted {json_file_path}")
    except IOError as e:
        print(f"Error writing to file {json_file_path}: {e}")
        return False
    
    return f"{query_name}.json"

def extract_prom_json_data(metric_file_path):
     metric_profile = read_json_file(metric_file_path)
     validate_metric_profile(metric_profile)
     output_dir = os.path.dirname(metric_file_path)
     for metric in metric_profile['metrics']:
         query_name = metric['name']
         query_expression = metric['query']
         start = unix_time(metric.get('start') if metric.get('start') is not None else metric_profile['global_config'].get('start'))
         end = unix_time(metric.get('end') if metric.get('end') is not None else metric_profile['global_config'].get('end'))
         step = metric.get('step') if metric.get('step') is not None else metric_profile['global_config'].get('step')
         json_file_name = curl_promethus_endpoint(query_name, start, end, step, query_expression, output_dir)
         file_path = os.path.join(output_dir, json_file_name)
         json_to_csv(file_path)
     
# if __name__ == '__main__':
#     parser = argparse.ArgumentParser(description="command line options for promethus data processing.")
#     parser.add_argument('-p', '--profile', type=str, help="promethus metric profile path")
    
#     args = parser.parse_args()
#     if args.profile:
#         extract_prom_json_data(metric_profile)

extract_prom_json_data("/home/guoqingli/work/ocp-workspace/scripts/promethus/metric_profiles/desche_cpu_utilization_profile")