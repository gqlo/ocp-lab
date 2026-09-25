vms=$(oc get vm | awk '{print $1}')

for vm in $vms; do
    virtctl restart $vm
done
