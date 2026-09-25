#! /bin/bash
# sort vmi by it's scheduled node
declare -A node_vmi

vmi_file="vmis.txt"

while IFS= read -r line; do
  node=$(echo $line | awk '{print $5}' )
  vmi_name=$(echo $line | awk '{print $1}')
  node_vmi[$node]="${node_vmi[$node]} $vmi_name"
done < "$vmi_file"

for ((i=1; i<=64; i=i*2)); do
   for node in "${!node_vmi[@]}"; do 
      read -ra same_node_arr <<< ${node_vmi[$node]}
      echo "$node: ${same_node_arr[@]:0:$i}" >> batch-$i.txt
   done
done



