# NetApp setup notes

## Catalog

- [Lab environment](#lab-environment)
- [NetApp storage](#netapp-storage)
- [Discover SVM name (required for backend JSON)](#discover-svm-name-required-for-backend-json)
- [Create backend — success](#create-backend--success)
- [StorageClass (`trident-nfs-svm`)](#storageclass-trident-nfs-svm)
- [Verify NFS is providing the storage](#verify-nfs-is-providing-the-storage)
- [Trident backend create — pod vs host path to ONTAP](#trident-backend-create--pod-vs-host-path-to-ontap)
  - [Symptom](#symptom)
  - [Host path works](#host-path-works-node-e45-h14-000-r650-ip-10200028)
  - [Pod path fails (`routingViaHost`)](#pod-path-fails-even-with-routingviahost-true)
  - [tcpdump on the storage NIC](#tcpdump-on-the-storage-nic-while-pod-curls--create-backend-runs)
  - [Potential reason — outbound SNAT vs return path](#potential-reason--outbound-snat-vs-return-path)
  - [Conclusion](#conclusion)
  - [Fix applied — `hostNetwork: true`](#fix-applied--trident-controller-hostnetwork-true)
- [Prerequisite — nmstate operator](#prerequisite--nmstate-operator)

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
| SVM (vserver) | `nfs` (not `svm_nfs`) |

Trident ONTAP NAS backend: `trident-ontap-nas-backend.json` (`managementLIF` /
`dataLIF` = `10.200.0.10`, `"svm": "nfs"`, `vsadmin` credentials). Apply after
Trident is installed **and** the controller can reach ONTAP (see hostNetwork
section below):

```bash
tridentctl -n trident create backend -f trident-ontap-nas-backend.json
```

## Discover SVM name (required for backend JSON)

`"svm"` in the backend file must be the **exact** ONTAP vserver name
(case-sensitive). `backendName` is only Trident’s label.

Wrong name fails after network is fixed, e.g.:

```text
could not create backend: ... error reading SVM details: API status: failed,
Reason: Specified vserver not found, Code: 15698 (400 Bad Request)
```

List SVMs via ONTAP REST (from a storage node / hostNetwork path):

```bash
curl -sk -u 'vsadmin:g0g0netapp' \
  'https://10.200.0.10/api/svm/svms?fields=name'
```

Lab response:

```json
{
  "records": [
    {
      "uuid": "9ec45fff-ba21-11e7-a5dc-00a098b948b8",
      "name": "nfs"
    }
  ],
  "num_records": 1
}
```

Set in `trident-ontap-nas-backend.json`:

```json
"svm": "nfs"
```

Notes:

- `vsadmin` is SVM-scoped; `/api/svm/svms` is the right check (not `/api/cluster`).
- `/api/cluster` often returns 401 for `vsadmin` even with a correct password.

## Create backend — success

With hostNetwork on the controller and `"svm": "nfs"`:

```bash
./tridentctl create backend -f trident-ontap-nas-backend.json -n trident
```

```text
+---------+----------------+--------------------------------------+--------+------------+---------+
|  NAME   | STORAGE DRIVER |                 UUID                 | STATE  | USER-STATE | VOLUMES |
+---------+----------------+--------------------------------------+--------+------------+---------+
| nfs-svm | ontap-nas      | 21f5a071-a270-4a14-9d42-ee626f24820e | online | normal     |       0 |
+---------+----------------+--------------------------------------+--------+------------+---------+
```

Verify later:

```bash
./tridentctl get backend -n trident
```

## StorageClass (`trident-nfs-svm`)

Manifest: `trident-nfs-svm-storageclass.yaml`. Apply after the backend is
`online`:

```bash
oc apply -f trident-nfs-svm-storageclass.yaml
oc get sc trident-nfs-svm
```

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: trident-nfs-svm
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: csi.trident.netapp.io
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
parameters:
  backendType: "ontap-nas"
```

### How it selects the backend

The StorageClass does **not** reference backend name `nfs-svm`. Binding is:

| Field | Role |
|-------|------|
| `provisioner: csi.trident.netapp.io` | Hand PVCs to Trident CSI |
| `parameters.backendType: ontap-nas` | Use any online Trident backend with `storageDriverName: ontap-nas` |
| SC `metadata.name` (`trident-nfs-svm`) | Kubernetes label only — not the ONTAP/Trident backend name |

Lab has a single `ontap-nas` backend (`nfs-svm`), so `backendType: ontap-nas`
is enough. With multiple `ontap-nas` backends, narrow with Trident `selector`
/ storage pool parameters (match labels on the backend), or you may get an
arbitrary eligible backend.

`is-default-class: "true"` makes this the default for PVCs that omit
`storageClassName` (ensure no other default SC conflicts).

## Verify NFS is providing the storage

Trident `ontap-nas` mounts NFS on the **node** (host netns), then bind-mounts
into the virt-launcher / consumer pod. Confirm on the node that schedules the
workload (example: VM `vm-08e7f4-1` on `e45-h13-000-r650`).

1. PVC → PV → NFS server/path:

```bash
oc get pvc vm-08e7f4-1 -n vm-08e7f4-ns-1 \
  -o jsonpath='sc={.spec.storageClassName} pv={.spec.volumeName}{"\n"}'

oc get pv $(oc get pvc vm-08e7f4-1 -n vm-08e7f4-ns-1 -o jsonpath='{.spec.volumeName}') \
  -o jsonpath='nfs://{.spec.nfs.server}{.spec.nfs.path}{"\n"}'
```

Expect `storageClassName: trident-nfs-svm` and `nfs://10.200.0.10:/cluster01_pvc_...`.

2. Node mount (CSI volume under kubelet):

```bash
oc debug node/e45-h13-000-r650
# inside:
chroot /host
mount | grep nfs
# or: findmnt -t nfs,nfs4
```

Lab example (VM disk PVC mounted as NFSv4.0 from the dataLIF, client on the
storage NIC):

```text
10.200.0.10:/cluster01_pvc_e5086731_cd77_43b3_9972_1960ace10632 on
  /var/lib/kubelet/pods/.../volumes/kubernetes.io~csi/pvc-e5086731-.../mount
  type nfs4 (rw,relatime,vers=4.0,...,proto=tcp,...,clientaddr=10.200.0.27,...,addr=10.200.0.10)
```

| Field | Meaning |
|-------|---------|
| `10.200.0.10:/cluster01_pvc_...` | ONTAP dataLIF + Trident volume export |
| `kubernetes.io~csi/pvc-.../mount` | kubelet CSI mount for that PVC |
| `vers=4.0` | Matches backend `nfsMountOptions: nfsvers=4.0` |
| `clientaddr=10.200.0.27` | Node storage IP on `ens2f0np0` (not the OVN pod IP) |
| `addr=10.200.0.10` | NFS server |

If `mount | grep nfs` shows that line on the VM’s node, NFS (not local disk /
RBD) is backing the volume.

## Trident backend create — pod vs host path to ONTAP

### Symptom

`tridentctl create backend` hangs, then times out talking to Trident’s local REST API:

```text
Post "http://127.0.0.1:8000/trident/v1/backend": context deadline exceeded
```

Bastion `tridentctl` does **not** open a socket to ONTAP. It runs
`oc exec` into the controller and posts to `127.0.0.1:8000` inside the pod.
Controller logs show `AddBackend` parse the config and resolve
`managementLIF` → `10.200.0.10`, then stall (no success/fail for that
request).

NNCP puts `10.200.0.x` on the **node** NIC `ens2f0np0`. The Trident
controller pod still has only CNI `eth0` (e.g. `10.129.x.x`). Those are
different network namespaces.

### Host path works (node `e45-h14-000-r650`, IP `10.200.0.28`)

```bash
oc get pod -n trident -l app=controller.csi.trident.netapp.io -o wide
# example: controller on e45-h14-000-r650

oc debug node/e45-h14-000-r650 -- chroot /host ip -4 addr show ens2f0np0
oc debug node/e45-h14-000-r650 -- chroot /host ip route get 10.200.0.10
# → 10.200.0.10 dev ens2f0np0 src 10.200.0.28

oc debug node/e45-h14-000-r650 -- chroot /host \
  curl -vk --connect-timeout 5 https://10.200.0.10/api/cluster
# → TLS OK, HTTP 401 without credentials (API alive)
```

Do not use ping alone — ONTAP management LIFs often ignore ICMP.

`/api/cluster` needs a **cluster** admin. `vsadmin` is SVM-scoped; test it
with SVM APIs (e.g. `/api/svm/svms`), not `/api/cluster`.

### Pod path fails (even with `routingViaHost: true`)

OVN setting (cluster-wide):

```bash
oc patch network.operator cluster --type merge -p \
  '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}}'

oc get network.operator cluster \
  -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.routingViaHost}{"\n"}'
# → true
```

`routingViaHost` does **not** add `ens2f0np0` inside the pod. `ip a` in the
pod still shows only `eth0`. The change is how OVN hands egress to the
**host** routing table.

Debug from the controller’s network namespace (ocp-trace image):

```bash
oc debug -it pod/<trident-controller-pod> \
  --image=quay.io/rh_ee_lguoqing/ocp-trace:4.22.0 \
  --target=trident-main \
  -n trident

# inside debug shell
curl -vk --connect-timeout 5 https://10.200.0.10/api/cluster
```

### tcpdump on the storage NIC (while pod curls / create backend runs)

On the node hosting the controller:

```bash
oc debug node/e45-h14-000-r650 -- chroot /host \
  tcpdump -i ens2f0np0 -nn host 10.200.0.10 and port 443
```

Observed (pod egress SNATed to storage IP):

```text
10.200.0.28 → 10.200.0.10:443  Flags [S]     (SYN out)
10.200.0.10 → 10.200.0.28      Flags [S.]    (SYN-ACK back)
… SYN / SYN-ACK retransmits …
(never an ACK from 10.200.0.28)
```

Client MSS `1360` matches OVN pod MTU (1400), not a plain host curl.

| Finding | Meaning |
|---------|---------|
| SYN leaves `ens2f0np0` as `10.200.0.28` | `routingViaHost` + host route/SNAT to storage NIC work |
| SYN-ACK returns to `10.200.0.28` | NetApp and L2 are fine |
| No ACK, handshake never completes | Reply not delivered back into the pod/OVN TCP stack |
| Host `curl` fully completes TLS + HTTP | Node path OK; only **pod return path** is broken |

### Potential reason — outbound SNAT vs return path

`routingViaHost` only changes **egress**: OVN hands the packet to the host
routing table, which SNATs the pod IP (`10.129.x.x`) to `10.200.0.28` and
sends it out `ens2f0np0`. The pod still has only `eth0`; it never owns that
storage IP.

The SYN-ACK comes back to **`10.200.0.28` (host address)**. For the pod to
complete TCP, the host must reverse-SNAT and inject the reply into OVN. That
handoff is what fails on this secondary NIC — the kernel treats the packet as
local to the node (or drops it via `rp_filter` / asymmetric path), so the
pod’s stack never sees the SYN-ACK (hence no ACK on the wire).

Host `curl` works because client and `10.200.0.28` share one netns — no
OVN reverse hop. `hostNetwork` / Multus avoid the same gap by putting the
client on the storage path directly.

### Conclusion

Secondary NIC + CNI pod egress: outbound works, return path into OVN fails.
`routingViaHost` alone is not enough here.

Practical fixes for Trident controller → `managementLIF`:

1. Run controller with `hostNetwork: true` (lab choice below), or
2. Multus attachment on `10.200.0.0/24`, or
3. Further OVN/host tuning (`rp_filter`, forwarding, SNAT) — more fragile for lab use.

NFS data path on workers still relies on node `ens2f0np0` IPs from NNCP
(CSI node mounts use the host network namespace).

### Fix applied — Trident controller `hostNetwork: true`

Shares the node network namespace (same path as the working host `curl` to
`10.200.0.10`). Supported on TridentOrchestrator (Trident 25.10+; lab is 26.02.x).

```bash
oc get tridentorchestrator -A
# NAME      AGE
# trident   …

oc patch tridentorchestrator trident --type merge \
  -p '{"spec":{"hostNetwork":true}}'
```

Verify the controller rolled and is on host network (still prefer a storage
worker that has `ens2f0np0` in `10.200.0.0/24`):

```bash
oc get pod -n trident -l app=controller.csi.trident.netapp.io -o wide
# example after patch:
# trident-controller-…   6/6  Running  …  10.1.92.80  e45-h14-000-r650
# podIP is the node primary IP (not 10.129.x.x OVN)

oc get pod -n trident -l app=controller.csi.trident.netapp.io \
  -o jsonpath='hostNetwork={.spec.hostNetwork} podIP={.status.podIP} hostIP={.status.hostIP}{"\n"}'
# → hostNetwork=true  podIP≈hostIP (node address)
```

`podIP` may be the node’s primary IP (e.g. `10.1.92.80`); traffic to
`10.200.0.10` still follows the host route out `ens2f0np0` with
`src 10.200.0.28`.

Retest ONTAP reachability, then create the backend (after confirming SVM name
— see **Discover SVM name** above):

```bash
oc debug -it pod/<trident-controller-pod> \
  --image=quay.io/rh_ee_lguoqing/ocp-trace:4.22.0 \
  --target=trident-main -n trident
# inside: curl -vk --connect-timeout 5 https://10.200.0.10/api/cluster

tridentctl -n trident create backend -f trident-ontap-nas-backend.json
```

Do **not** only `oc patch deployment trident-controller … hostNetwork` — the
operator may reconcile it away; set it on `TridentOrchestrator` instead.

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
