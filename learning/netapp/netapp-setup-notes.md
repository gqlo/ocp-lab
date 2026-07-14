# NetApp setup notes

## Lab environment

| Component | Specification |
|-----------|---------------|
| Cluster | 10 worker nodes, 3 master nodes |
| Node type R650 | 5 nodes — 112 CPUs, 512 GB RAM |
| Node type R640 | 5 nodes — 80 CPUs, 376 GB RAM |
| Network | 25 Gbps; `ens2f0np0` used for NetApp storage |
| Bastion | `e26-h03-000-r640.rdu2.scalelab.redhat.com` |

Storage subnet: `10.200.0.0/24` (routeless, on-link). Nine workers get static
IPs on `ens2f0np0` via NNCP (see verification below).

## NetApp storage

| Attribute | Value |
|-----------|-------|
| NFS server | `10.200.0.10` |
| Export path | `/nfs_data_01` |
| Volume size | 1 TB |
| Protocols | NFSv3, NFSv4.0 |
| Access | Read-write |
| NetApp cluster | `b02-h37-ntap-a300` |

## Prerequisite — nmstate operator

NNCPs require the **Kubernetes NMState Operator** (`openshift-nmstate` namespace).

Verify before applying:

```bash
oc get nmstate
oc get pods -n openshift-nmstate
```

Expect an `nmstate` CR and all `nmstate-handler` pods `Running`. If the operator is not installed, install **Kubernetes NMState Operator** from OperatorHub, then create the instance:

```bash
oc apply -f - <<'EOF'
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
spec: {}
EOF
```

Apply all static NNCPs (run from this directory):

```bash
oc apply $(printf ' -f %s' storage-e*-nncp.yaml)
```

(`oc apply -f` accepts only one path per flag; the glob alone passes extra positional args.)

Check `ens2f0np0` IPv4 on all 9 storage workers:

```bash
for n in e26-h15-000-r640 e26-h17-000-r640 e29-h01-000-r640 e29-h03-000-r640 e29-h06-000-r640 e34-h01-000-r650 e45-h11-000-r650 e45-h13-000-r650 e45-h14-000-r650; do printf "%-22s %s\n" "$n" "$(oc debug node/$n --quiet -- chroot /host ip -4 -br addr show ens2f0np0 2>/dev/null | awk '{print $3}')"; done
```

Blank output = no IP assigned. Expected output:

```
e26-h15-000-r640       10.200.0.20/24
e26-h17-000-r640       10.200.0.21/24
e29-h01-000-r640       10.200.0.22/24
e29-h03-000-r640       10.200.0.23/24
e29-h06-000-r640       10.200.0.24/24
e34-h01-000-r650       10.200.0.25/24
e45-h11-000-r650       10.200.0.26/24
e45-h13-000-r650       10.200.0.27/24
e45-h14-000-r650       10.200.0.28/24
```
