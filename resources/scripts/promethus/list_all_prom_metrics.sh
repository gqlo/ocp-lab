#! /bin/bash
oc rsh -n openshift-monitoring prometheus-k8s-0 curl 'http://localhost:9090/api/v1/label/__name__/values'
