#!/bin/bash

verbose=-1

tflag=

help() {
    cat <<EOF
Usage: ${0##*/} [-v] [-q] [-t] [command [args...]]
    -v  Print verbose messages (default when run interactively)
    -q  Do not print messages (default when run noninteractively)
    -t  Do not allocate a tty
EOF
    exit 1
}

while getopts vqth opt "$@" ; do
    # shellcheck disable=SC2220
    case "$opt" in
	v) verbose=1 ;;
	q) verbose=0 ;;
	t) tflag=-t  ;;
	h) help      ;;
    esac
done

shift $((OPTIND-1))

if ((verbose < 0)) ; then
    if [[ -n "$*" ]] ; then
	verbose=0
    else
	verbose=1
    fi
fi

msg() {
    if ((verbose)) ; then echo "$*" 1>&2; fi
}

ceph_enabled=$(oc get storagecluster ocs-storagecluster -n openshift-storage -o json | jq -r '.spec.enableCephTools')

if [[ "$ceph_enabled" != "true" ]]; then
  oc patch storagecluster ocs-storagecluster -n openshift-storage --type json --patch '[{ "op": "replace", "path": "/spec/enableCephTools", "value": true }]'
  msg "Patched: enableCephTools set to true."
else
  msg "No patch needed: enableCephTools is already set to true."
fi


NAMESPACE="openshift-storage"
LABEL="app=rook-ceph-tools"
POD_STATUS="Running"

# Loop until the pod is found and is in the Running state
while true; do
    POD=$(oc -n $NAMESPACE get pod -l "$LABEL" -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)

    if [ -z "$POD" ]; then
        msg "Pod not found, waiting..."
    else
        STATUS=$(oc -n $NAMESPACE get pod "$POD" -o jsonpath="{.status.phase}")
        if [ "$STATUS" == "$POD_STATUS" ]; then
            msg "Pod $POD is up and running."
            break
        else
            msg "Pod $POD found but not in Running state (current state: $STATUS), waiting..."
        fi
    fi
    msg "Waiting for the pod with label $LABEL in namespace $NAMESPACE to be up and running..."
    sleep 2
done


oc -n openshift-storage rsh ${tflag:+"$tflag"} "$(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name)" "$@"

