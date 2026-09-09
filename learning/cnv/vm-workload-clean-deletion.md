# CNV VM workload clean deletion

**Last Updated:** 2026-09-09

Lab note for tearing down KubeVirt / OpenShift Virtualization workloads at scale
without leaving cluster-scoped storage behind. Focus is on `oc` commands; VM stop
still uses `virtctl`.

## Catalog

- [Typical timeline at scale](#typical-timeline-at-scale)
- [Notes](#notes)
- [Lesson (short)](#lesson-short)
- [Scope: what you are deleting](#scope-what-you-are-deleting)
- [1. List what exists](#1-list-what-exists)
  - [Single namespace](#single-namespace)
  - [By label (cluster-wide)](#by-label-cluster-wide)
  - [Quick counts](#quick-counts)
  - [VM status breakdown](#vm-status-breakdown)
- [2. Stop VMs gracefully](#2-stop-vms-gracefully)
- [3. Delete namespaced objects](#3-delete-namespaced-objects)
  - [Option A: delete the namespace (recommended for full teardown)](#option-a-delete-the-namespace-recommended-for-full-teardown)
  - [Option B: delete VMs only (keep namespace)](#option-b-delete-vms-only-keep-namespace)
  - [Option C: delete individual resource types](#option-c-delete-individual-resource-types)
- [4. Monitor cleanup](#4-monitor-cleanup)
  - [Single namespace](#single-namespace-1)
  - [Multiple namespaces (by name pattern or label)](#multiple-namespaces-by-name-pattern-or-label)
  - [Count loop (poll until clean)](#count-loop-poll-until-clean)
- [What gets deleted vs what lingers](#what-gets-deleted-vs-what-lingers)
  - [Deleted with namespace (cascade, synchronous)](#deleted-with-namespace-cascade-synchronous)
  - [Cleaned up asynchronously after PVC delete](#cleaned-up-asynchronously-after-pvc-delete)
  - [When cleanup stalls (dangling objects)](#when-cleanup-stalls-dangling-objects)
- [Manual Ceph storage checks](#manual-ceph-storage-checks)
  - [Open a Ceph shell](#open-a-ceph-shell)
  - [Before and after teardown — snapshot these](#before-and-after-teardown--snapshot-these)
  - [Quick one-liner to watch during cleanup](#quick-one-liner-to-watch-during-cleanup)
  - [Correlate K8s PV count with RBD images](#correlate-k8s-pv-count-with-rbd-images)
  - [Inspect a specific RBD image](#inspect-a-specific-rbd-image)
  - [What to expect at 10k VMs](#what-to-expect-at-10k-vms)
- [Protected namespaces](#protected-namespaces)
- [Minimal cheat sheet](#minimal-cheat-sheet)
- [Delete all VM workloads on a cluster](#delete-all-vm-workloads-on-a-cluster)
  - [Flow](#flow)
  - [Discovery commands](#discovery-commands)
  - [Protected namespaces (never delete)](#protected-namespaces-never-delete)
  - [Per-batch delete loop](#per-batch-delete-loop)
  - [Per-namespace delete loop](#per-namespace-delete-loop)
  - [vstorm automation](#vstorm-automation)
- [Runtime path (VM start)](#runtime-path-vm-start)
  - [Object chain](#object-chain)
  - [Step-by-step flow](#step-by-step-flow)
  - [What each layer does](#what-each-layer-does)
  - [Inspect during provisioning](#inspect-during-provisioning)
- [Related](#related)

---

## Typical timeline at scale

Example from a 10k-VM workload across 10 namespaces (ODF/Ceph RBD, `./vstorm --delete-all`):

| Phase | Observed | Notes |
|-------|----------|-------|
| `virtctl stop` | ~14s | 10k requests at 200 parallel; individual failures are non-fatal |
| Wait for Stopped | ~14 min | All 10k VMs reached Stopped before namespace delete |
| `oc delete ns` | Immediate | All 10 namespaces accepted for deletion |
| PV/VA cleanup | ~2h | Async CSI/RBD reclaim until PVs and VolumeAttachments reach zero |
| End-to-end | ~2h 15m | From first stop request to full cleanup (no leftover PVs or VAs) |

### Observed run: `./vstorm --delete-all`

```text
[root@d20-h07-000-r650 vstorm]# ./vstorm --delete-all
2026-09-09T18:42:31Z Log file created: logs/vstorm-2ffd92-2026-09-09T18:42:31Z.log
Found vstorm batches:
  vstorm-2b0d37  (10 namespaces, 10000 VMs)

Delete ALL batches and VM namespaces above? This is irreversible. [y/N] y
Resources for batch 'vstorm-2b0d37':

Namespaces: 10
VirtualMachines: 10000

2026-09-09T18:43:04Z Stopping 10000 VM(s) (virtctl stop, 200 parallel) before delete...
2026-09-09T18:43:18Z Stop requests sent for 10000 VM(s)
2026-09-09T18:43:18Z Waiting for 10000 VM(s) to reach Stopped...
  10000/10000 VMs stopped
2026-09-09T18:56:54Z All 10000 VM(s) are Stopped
2026-09-09T18:56:54Z Deleting namespaces for batch 'vstorm-2b0d37'...
namespace "vstorm-2b0d37-ns-1" deleted
namespace "vstorm-2b0d37-ns-10" deleted
namespace "vstorm-2b0d37-ns-2" deleted
namespace "vstorm-2b0d37-ns-3" deleted
namespace "vstorm-2b0d37-ns-4" deleted
namespace "vstorm-2b0d37-ns-5" deleted
namespace "vstorm-2b0d37-ns-6" deleted
namespace "vstorm-2b0d37-ns-7" deleted
namespace "vstorm-2b0d37-ns-8" deleted
namespace "vstorm-2b0d37-ns-9" deleted
2026-09-09T18:56:54Z Monitoring cleanup for batch 'vstorm-2b0d37' (namespaces, PVCs, PVs, VolumeAttachments; refresh every 2s)...
  namespaces=0    PVCs=0    PVs=0    VolumeAttachments=0
2026-09-09T20:57:36Z Batch 'vstorm-2b0d37' fully cleaned up (no leftover namespaces, PVCs, PVs, or VolumeAttachments)
2026-09-09T20:57:36Z All vstorm batches and VM namespaces deleted.
```

## Notes

**Tested at 10k VMs** (10 namespaces, ODF/Ceph RBD backend). When the full
procedure below is followed — stop VMs first, delete namespaces, then monitor
until PVs and VolumeAttachments reach zero — teardown worked smoothly. Namespace
delete itself returns in seconds even at that scale.

**Improper or rushed deletion can stall the async cleanup chain.** Skipping the
stop step, deleting namespaces with `--wait=false` and walking away, or not
monitoring afterward means PVCs are removed but PV/VA/RBD cleanup may never
finish. Common stuck points:

| Leftover | Scope | Risk |
|----------|-------|------|
| `VolumeAttachment` | cluster | CSI volume still attached; blocks PV reclaim |
| `PersistentVolume` | cluster | PVC gone but PV stuck in `Released` / `Terminating` |
| Orphan Ceph RBD images | storage backend | PVC/PV removed from Kubernetes but RBD image not deleted — **consumes real disk** |

On ODF, each VM disk is an RBD image in `ocs-storagecluster-cephblockpool` (or the
pool backing your StorageClass). With `reclaimPolicy: Delete`, the CSI driver
removes the RBD image when the PV is deleted — but if the chain stalls (VA still
attached, CSI overloaded, namespace torn down while VMIs still running), the
Kubernetes objects linger or disappear while the RBD image remains.

**Wait for automatic cleanup before intervening.** With ODF's default
`reclaimPolicy: Delete`, `oc delete ns` triggers an async chain: PVC deleted →
PV deleted by CSI → VolumeAttachment detached → RBD image removed. At 10k VMs
this can take hours but should complete without manual steps. Only force-delete
stuck PVs/VAs or purge RBD images if monitoring shows objects blocked long
after PVCs are gone (see section 4).

## Lesson (short)

A clean VM teardown has three phases:

1. **Stop** VMs (`virtctl stop`) so VMIs shut down before namespaces are removed.
2. **Delete** namespaced resources — usually by deleting the **namespace** or
   labeled VMs — so VMs, DVs, PVCs, snapshots, and related objects cascade away.
3. **Monitor** cluster-scoped storage — PVs and VolumeAttachments are cleaned up
   **asynchronously** after PVCs are removed (not synchronously with namespace
   delete) and can take hours at large scale (see timeline above).

## Scope: what you are deleting

Pick a scope before running commands:

| Scope | How to target |
|-------|----------------|
| One namespace | `NS=my-vm-ns` |
| Label selector | `-l app=my-workload` or `-l batch-id=abc123` |
| All VMs in a namespace | `oc delete vm -n $NS --all` |

Set variables for the examples below:

```bash
NS=my-vm-ns          # single namespace
LABEL_KEY=batch-id   # optional label selector
LABEL_VAL=abc123
```

## 1. List what exists

### Single namespace

```bash
oc get vm,vmi,datavolume,volumesnapshot,pvc,secret,svc -n "$NS"
```

### By label (cluster-wide)

```bash
oc get vm -A -l "$LABEL_KEY=$LABEL_VAL"
oc get datavolume -A -l "$LABEL_KEY=$LABEL_VAL"
oc get volumesnapshot -A -l "$LABEL_KEY=$LABEL_VAL"
oc get ns -l "$LABEL_KEY=$LABEL_VAL"
```

### Quick counts

```bash
oc get vm -n "$NS" --no-headers | wc -l
oc get vm -A -l "$LABEL_KEY=$LABEL_VAL" --no-headers | wc -l
oc get pvc -n "$NS" --no-headers | wc -l
```

### VM status breakdown

```bash
oc get vm -A --no-headers | awk '{print $4}' | sort | uniq -c
```

## 2. Stop VMs gracefully

`oc` does not stop VMs — use `virtctl`:

```bash
# All VMs in one namespace
oc get vm -n "$NS" --no-headers -o custom-columns=NAME:.metadata.name \
  | xargs -P 50 -I{} virtctl stop {} -n "$NS"

# All VMs matching a label (cluster-wide)
oc get vm -A -l "$LABEL_KEY=$LABEL_VAL" --no-headers \
  | awk '{print $1, $2}' \
  | xargs -P 200 -L 1 bash -c 'virtctl stop "$2" -n "$1"' _
```

Check that VMs reached `Stopped`:

```bash
oc get vm -n "$NS" -o custom-columns=NAME:.metadata.name,STATUS:.status.printableStatus
oc get vm -A -l "$LABEL_KEY=$LABEL_VAL" --no-headers | awk '{print $1, $2, $4}'
```

Watch until none are non-Stopped:

```bash
watch -n 2 "oc get vm -n $NS --no-headers | awk '\$3 != \"Stopped\" {print; c++} END {exit c}'"
```

At large scale, allow 30+ minutes for all VMIs to stop before proceeding.

## 3. Delete namespaced objects

### Option A: delete the namespace (recommended for full teardown)

Cascade-deletes VMs, VMIs, DVs, PVCs, snapshots, secrets, services, UDNs, and
virt-launcher pods in that namespace:

```bash
oc delete ns "$NS" --wait=false
```

Multiple namespaces by label:

```bash
oc delete ns -l "$LABEL_KEY=$LABEL_VAL" --wait=false
```

`--wait=false` returns immediately; finalizer cleanup continues in the background.
Namespace delete removes PVCs, which kicks off automatic PV/VA/RBD cleanup on ODF
(`reclaimPolicy: Delete`). Use `--wait=false` so you can monitor that async
chain instead of blocking until every finalizer clears.

### Option B: delete VMs only (keep namespace)

```bash
oc delete vm -n "$NS" --all
oc delete vm -A -l "$LABEL_KEY=$LABEL_VAL"
```

PVCs and DVs are not removed unless you delete them explicitly or the VM spec
owned them and garbage collection runs:

```bash
oc delete datavolume -n "$NS" --all
oc delete pvc -n "$NS" --all
oc delete volumesnapshot -n "$NS" --all
```

### Option C: delete individual resource types

```bash
oc delete vm,vmi,datavolume,volumesnapshot,pvc,secret,svc -n "$NS" --all
```

## 4. Monitor cleanup

After namespace delete, watch these four object types. Namespace and PVC counts
usually drop to zero quickly; PVs and VolumeAttachments are the slow part.

### Single namespace

```bash
oc get ns "$NS"
oc get pvc -n "$NS"
oc get pv -o custom-columns=NAME:.metadata.name,NS:.spec.claimRef.namespace,STATUS:.status.phase \
  | awk -v ns="$NS" '$2 == ns'
oc get volumeattachment
```

### Multiple namespaces (by name pattern or label)

For namespaces matching a pattern (e.g. `workload-ns-1`, `workload-ns-2`):

```bash
NS_PAT='^workload-ns-[0-9]+$'

oc get ns -l "$LABEL_KEY=$LABEL_VAL"
oc get pvc -A | awk -v pat="$NS_PAT" '$1 ~ pat'
oc get pv -o custom-columns=NAME:.metadata.name,NS:.spec.claimRef.namespace,STATUS:.status.phase \
  | awk -v pat="$NS_PAT" '$2 ~ pat'
oc get volumeattachment
```

### Count loop (poll until clean)

```bash
NS=my-vm-ns   # single namespace; or set NS_PAT for multiple

while true; do
  ns_n=$(oc get ns "$NS" --no-headers 2>/dev/null | wc -l)
  pvc_n=$(oc get pvc -n "$NS" --no-headers 2>/dev/null | wc -l)

  pv_n=$(oc get pv -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.claimRef.namespace}{"\n"}{end}' 2>/dev/null \
    | awk -v ns="$NS" '$2 == ns {print $1}' | wc -l)

  pv_names=$(oc get pv -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.claimRef.namespace}{"\n"}{end}' 2>/dev/null \
    | awk -v ns="$NS" '$2 == ns {print $1}')
  va_n=$(oc get volumeattachment -o jsonpath='{range .items[*]}{.spec.source.persistentVolumeName}{"\n"}{end}' 2>/dev/null \
    | grep -Ff <(echo "$pv_names") | wc -l)

  echo "namespace=$ns_n  PVCs=$pvc_n  PVs=$pv_n  VolumeAttachments=$va_n"
  [[ "$ns_n" -eq 0 && "$pvc_n" -eq 0 && "$pv_n" -eq 0 && "$va_n" -eq 0 ]] && break
  sleep 2
done
echo "Cleanup complete."
```

## What gets deleted vs what lingers

### Deleted with namespace (cascade, synchronous)

| Object | API | Notes |
|--------|-----|-------|
| Namespace | `v1/Namespace` | Entry point for full teardown |
| VirtualMachine | `kubevirt.io/VirtualMachine` | VM spec |
| VirtualMachineInstance | `kubevirt.io/VirtualMachineInstance` | Running instance |
| DataVolume | `cdi.kubevirt.io/DataVolume` | CDI import/clone |
| PersistentVolumeClaim | `v1/PersistentVolumeClaim` | VM and DV disks |
| VolumeSnapshot | `snapshot.storage.k8s.io/VolumeSnapshot` | Clone source snapshots |
| Secret | `v1/Secret` | Cloud-init userdata |
| Service | `v1/Service` | SSH / app exposure |
| UserDefinedNetwork | `k8s.ovn.org/UserDefinedNetwork` | OVN primary UDN |
| virt-launcher Pod | `v1/Pod` | KubeVirt launcher |

### Cleaned up asynchronously after PVC delete

This is the reverse of [Runtime path (VM start)](#runtime-path-vm-start).

These are cluster-scoped and not deleted in the same API call as the namespace,
but ODF (`reclaimPolicy: Delete`) removes them automatically once PVCs are gone:

```text
PVC deleted
  → PV deleted by CSI provisioner
    → VolumeAttachment detached and removed
      → CSI DeleteVolume → RBD image deleted in Ceph
```

| Object | API | Typical timing |
|--------|-----|----------------|
| PersistentVolume | `v1/PersistentVolume` | Minutes to hours after PVC is gone |
| VolumeAttachment | `storage.k8s.io/VolumeAttachment` | During CSI detach |
| Ceph RBD image | (backend, not a K8s object) | When CSI DeleteVolume succeeds |
| VolumeSnapshotContent | `snapshot.storage.k8s.io/VolumeSnapshotContent` | Snapshot controller; can lag |

### When cleanup stalls (dangling objects)

The chain above breaks if VMIs are still running (VA still attached), CSI is
overloaded, or finalizers are stuck. Symptoms:

| Symptom | Likely cause |
|---------|--------------|
| PV in `Terminating` for hours | VA still attached or CSI finalizer stuck |
| VA remains after PVC gone | Volume still mounted on a node |
| RBD image count not dropping | PV reclaim never completed; K8s object may already be gone |

With `reclaimPolicy: Retain` (not ODF default), PVs stay in `Released` and RBD
images are **not** auto-deleted — manual cleanup is expected.

**Intervention:** wait for automatic cleanup first. Only force-delete a stuck PV/VA
or purge an RBD image after confirming the PVC is gone, no pod still uses the
volume, and no VolumeAttachment references it.

Check RBD image count from **rook-ceph-tools** (image name usually matches the
PV name):

```bash
oc rsh -n openshift-storage deploy/rook-ceph-tools -- \
  rbd ls ocs-storagecluster-cephblockpool | wc -l
```

Compare before and after teardown. Unexpected growth after PVCs/PVs reach zero
means CSI reclaim failed and images were orphaned.

## Manual Ceph storage checks

Kubernetes object counts (PVC, PV, VolumeAttachment) can reach zero while Ceph
still holds disk. Check pool usage and RBD image count from **rook-ceph-tools**
to confirm storage was actually reclaimed.

### Open a Ceph shell

```bash
# One-shot command
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph -s

# Interactive shell
oc rsh -n openshift-storage deploy/rook-ceph-tools

# Or use the lab helper (enables ceph tools if needed)
~/work/ocp-lab/scripts/ceph/ceph-terminal.sh
```

VM block volumes on ODF typically use pool `ocs-storagecluster-cephblockpool`
(StorageClass `ocs-storagecluster-ceph-rbd` or
`ocs-storagecluster-ceph-rbd-virtualization`).

### Before and after teardown — snapshot these

Run **before** delete and again after K8s monitoring shows PV/VA at zero:

```bash
POOL=ocs-storagecluster-cephblockpool

# Cluster health
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph -s

# Pool space (STORED = logical data, USED = raw with replication)
oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph df detail \
  | grep -E "^POOL|^---|${POOL}"

# RBD image count in the VM block pool
oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  rbd ls "$POOL" | wc -l

# CSI-provisioned VM volumes only (image names start with csi-vol-)
oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  rbd ls "$POOL" | grep -c '^csi-vol-'
```

Example `ceph df` line for the block pool:

```text
POOL                      ID  PGs  STORED   OBJECTS  USED     %USED  MAX AVAIL
ocs-storagecluster-cephblockpool  2  256  811 GiB  217.38k  2.4 TiB   3.73  20 TiB
```

| Column | Meaning |
|--------|---------|
| `STORED` | Logical data in the pool (what you care about for "did space come back") |
| `USED` | Raw bytes on OSDs including replication overhead |
| `OBJECTS` | RADOS objects (rises with RBD image/snapshot count) |
| `%USED` | Pool utilization |

After a large teardown, `STORED`, `OBJECTS`, and `rbd ls` count should drop.
If K8s is clean but these stay high, orphan RBD images remain.

### Quick one-liner to watch during cleanup

```bash
watch -n 30 'oc exec -n openshift-storage deploy/rook-ceph-tools -- ceph df detail 2>/dev/null | grep ocs-storagecluster-cephblockpool; echo "---"; oc exec -n openshift-storage deploy/rook-ceph-tools -- rbd ls ocs-storagecluster-cephblockpool 2>/dev/null | wc -l'
```

### Correlate K8s PV count with RBD images

```bash
# PVs still bound to your workload namespaces
NS_PAT='^workload-ns-[0-9]+$'
oc get pv -o custom-columns=NAME:.metadata.name,NS:.spec.claimRef.namespace \
  | awk -v pat="$NS_PAT" '$2 ~ pat' | wc -l

# RBD images in the block pool
oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  rbd ls ocs-storagecluster-cephblockpool | wc -l
```

These should track together over time. A large gap (many RBD images, zero PVs)
indicates orphans.

### Inspect a specific RBD image

Image name usually matches the PV name (e.g. `csi-vol-<uuid>`):

```bash
POOL=ocs-storagecluster-cephblockpool
IMG=csi-vol-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

oc exec -n openshift-storage deploy/rook-ceph-tools -- rbd info "$POOL/$IMG"
oc exec -n openshift-storage deploy/rook-ceph-tools -- rbd du "$POOL/$IMG"
```

### What to expect at 10k VMs

| Metric | Before 10k VMs | After clean teardown |
|--------|----------------|----------------------|
| `rbd ls` count | ~10k (+ snapshots/clones if used) | Near pre-workload baseline |
| `ceph df` STORED | Grows with VM disks (and guest writes) | Drops as CSI deletes images |
| `OBJECTS` | High | Drops with image removal |

Reclaim can lag K8s object deletion by hours. Pool `STORED` may not drop until
all PV finalizers clear and CSI `DeleteVolume` completes for every volume.

**Warning:** do not `rbd rm` images manually unless you have confirmed the
matching PV/PVC is gone and no pod references the volume. See
[When cleanup stalls](#when-cleanup-stalls-dangling-objects) above.

## Protected namespaces

Do not delete system namespaces:

- `openshift*`
- `kube-*`, `kube-system`, `kube-public`, `kube-node-lease`
- `default`

## Minimal cheat sheet

```bash
NS=my-vm-ns

# List
oc get vm,vmi,pvc,datavolume -n "$NS"

# Stop (virtctl, not oc)
oc get vm -n "$NS" -o name | xargs -P 50 -I{} virtctl stop {} -n "$NS"

# Delete
oc delete ns "$NS" --wait=false

# Monitor
oc get ns "$NS"
oc get pvc -n "$NS"
oc get pv -o custom-columns=NAME:.metadata.name,NS:.spec.claimRef.namespace | awk -v ns="$NS" '$2 == ns'
oc get volumeattachment
```

Label-based variant:

```bash
# List / delete / monitor by label
oc get vm -A -l app=my-workload
oc delete ns -l app=my-workload --wait=false
oc get ns -l app=my-workload
oc get vm -A -l app=my-workload
```

## Delete all VM workloads on a cluster

Use this when tearing down **every** VM namespace on the cluster — not just one
batch or label. The flow has two discovery passes, one confirmation, then the
same stop → delete ns → monitor cycle for each target.

### Flow

```text
delete-all
  │
  ├─ 1. Discover vstorm-style batch namespaces
  │     oc get ns -l batch-id
  │     filter names matching {batch}-ns-{N}
  │     extract unique batch IDs
  │
  ├─ 2. Discover other VM namespaces
  │     oc get vm -A  →  unique namespaces
  │     minus batch namespaces from step 1
  │     minus protected (openshift*, kube-*, default, …)
  │
  ├─ 3. Show summary (batch count, VM count per batch/ns)
  │
  ├─ 4. Confirm once
  │
  ├─ 5. For each batch (step 1):
  │     stop all VMs (virtctl, parallel)
  │     wait for Stopped (best-effort)
  │     oc delete ns -l batch-id=<batch> --wait=false
  │     monitor ns / PVC / PV / VolumeAttachment until zero
  │
  └─ 6. For each other VM namespace (step 2):
        stop all VMs in namespace
        wait for Stopped (best-effort)
        oc delete ns <ns> --wait=false
        monitor ns / PVC / PV / VolumeAttachment until zero
```

Batches are processed first, then remaining non-batch VM namespaces. Each
target gets the full three-phase teardown from sections 2–4 above.

### Discovery commands

**Vstorm-style batches** (namespaces labeled `batch-id` matching `{batch}-ns-{N}`):

```bash
# All batch namespace names
oc get ns -l batch-id --no-headers \
  | awk '{print $1}' \
  | grep -E '^[a-zA-Z0-9._-]+-ns-[0-9]+$' \
  | sort -u

# Unique batch IDs extracted from namespace names
oc get ns -l batch-id --no-headers \
  | awk '{print $1}' \
  | grep -E '^[a-zA-Z0-9._-]+-ns-[0-9]+$' \
  | grep -oP '^[a-zA-Z0-9._-]+(?=-ns-[0-9]+$)' \
  | sort -u
```

**Other namespaces that contain VMs** (excluding batch namespaces and system ns):

```bash
# All namespaces with at least one VM
oc get vm -A --no-headers | awk '{print $1}' | sort -u

# Per-batch summary
BATCH=abc123
oc get ns -l batch-id="$BATCH" --no-headers | wc -l
oc get vm -A -l batch-id="$BATCH" --no-headers | wc -l
```

### Protected namespaces (never delete)

Skip these when building the "other VM namespaces" list:

- `openshift*`
- `kube-*`, `kube-system`, `kube-public`, `kube-node-lease`
- `default`

### Per-batch delete loop

For each batch ID from discovery:

```bash
BATCH=abc123

# Stop
oc get vm -A -l batch-id="$BATCH" --no-headers \
  | awk '{print $1, $2}' \
  | xargs -P 200 -L 1 bash -c 'virtctl stop "$2" -n "$1"' _

# Wait for Stopped (poll; proceed on timeout)
watch -n 2 "oc get vm -A -l batch-id=$BATCH --no-headers | awk '\$4 != \"Stopped\" {c++} END {exit c}'"

# Delete
oc delete ns -l batch-id="$BATCH" --wait=false

# Monitor (see section 4 count loop; NS_PAT=^${BATCH}-ns-[0-9]+$)
```

### Per-namespace delete loop

For each non-batch VM namespace:

```bash
NS=my-other-vm-ns

oc get vm -n "$NS" --no-headers \
  | awk -v ns="$NS" '{print ns, $1}' \
  | xargs -P 200 -L 1 bash -c 'virtctl stop "$2" -n "$1"' _

oc delete ns "$NS" --wait=false

# Monitor (see section 4 single-namespace commands)
```

### vstorm automation

[vstorm](https://github.com/gqlo/vstorm) implements this flow as `--delete-all`:

```bash
./vstorm --delete-all -y
```

Defaults: `STOP_PARALLEL=200`, `STOP_WAIT_TIMEOUT=1800s`, `DELETE_POLL_TIMEOUT=7200s`.
Per-batch safety check: refuses namespaces that do not match `{batch}-ns-{N}`.

## Runtime path (VM start)

When a VM is created or started, KubeVirt and CDI provision disks in the reverse
order of teardown. Understanding this chain explains why stopping VMs matters
before namespace delete (VA must detach) and why PVC delete kicks off async
PV/VA cleanup (see [Cleaned up asynchronously after PVC delete](#cleaned-up-asynchronously-after-pvc-delete)).

### Object chain

```text
VirtualMachine  (namespaced — VM spec)
    │
    ├── dataVolumeTemplates[]     ← template: "create this disk"
    │       └── DataVolume        (namespaced — CDI manages provisioning)
    │               │
    │               ├── spec.pvc / spec.storage  ← desired PVC shape (size, SC, accessMode)
    │               ├── spec.source                ← blank / snapshot / http / registry / …
    │               │
    │               └── creates & owns →  PVC     (namespaced — "I need a 20Gi disk")
    │                                           │
    │                                           └── binds to →  PV  (cluster — RBD image csi-vol-...)
    │                                                                   │
    │                                                                   └── VA  (cluster — attached on worker-N)
    │
    └── template.spec.volumes[]
            └── dataVolume.name: <same DV name>   ← VM disk points at the DV
                    └── mounted in virt-launcher Pod when VMI runs
```

The VM declares disks twice: `dataVolumeTemplates` tells KubeVirt/CDI what to
provision; `template.spec.volumes[].dataVolume.name` wires that disk into the
VMI (e.g. as `vda`).

### Step-by-step flow

```text
VM created (or started)
  → KubeVirt creates DataVolume(s) from dataVolumeTemplates
    → CDI provisions disk (clone / import / blank) and creates PVC
      → CSI provisioner creates PV and binds to PVC
        → VMI created; virt-launcher Pod scheduled
          → attach/detach controller creates VolumeAttachment
            → CSI attaches PV on node → kubelet mounts volume in Pod
```

With `volumeBindingMode: WaitForFirstConsumer` (common on ODF virtualization
StorageClasses), PV provisioning and binding may not happen until the
virt-launcher pod is scheduled.

### What each layer does

| Layer | Scope | Creator | Role |
|-------|-------|---------|------|
| VirtualMachine | namespaced | User / vstorm | Declares disks via `dataVolumeTemplates`; references them in `volumes` |
| DataVolume | namespaced | KubeVirt / CDI | Runs import/clone/blank provisioning; creates and owns the PVC |
| PersistentVolumeClaim | namespaced | CDI controller | Standard K8s storage claim; what the virt-launcher pod mounts |
| PersistentVolume | cluster | CSI provisioner (ODF) | Backing volume — one RBD image per disk (`csi-vol-…`) |
| VolumeAttachment | cluster | attach/detach controller | Records that PV is attached on a specific node |

A VM with OS disk + data disk has two DataVolumes → two PVCs → two PVs. Each
running VMI has one VolumeAttachment per attached block volume on its node.

### Inspect during provisioning

```bash
NS=my-vm-ns

oc get vm,vmi,datavolume,pvc -n "$NS"
oc get pv -o custom-columns=NAME:.metadata.name,NS:.spec.claimRef.namespace,STATUS:.status.phase \
  | awk -v ns="$NS" '$2 == ns'
oc get volumeattachment
```

DV status (`Pending`, `ImportInProgress`, `Succeeded`) tracks CDI provisioning.
PVC `Bound` means storage is reserved. VA appears once the virt-launcher pod is
scheduled and the volume is attached.

## Related

- [VMs stuck at Starting](vm-stuck-at-starting.md)
- [PVC vs snapshot clone](../ceph/pvc-vs-snapshot-clone.md) — RBD image layout and pool usage during clone
