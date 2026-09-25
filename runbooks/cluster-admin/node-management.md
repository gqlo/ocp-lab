# Node management — removing failed bare-metal workers

Lab notes from removing three `NotReady` worker nodes with hardware issues on a
large bare-metal ODF cluster (manual/UPI workers, no Machine API objects).

**Last Updated:** 2026-08-24

## Catalog

- [Context](#context)
- [Pre-removal checks](#pre-removal-checks)
  - [Node state](#node-state)
  - [Machine API](#machine-api)
  - [ODF / storage pods on the nodes](#odf--storage-pods-on-the-nodes)
- [Remove nodes from the cluster](#remove-nodes-from-the-cluster)
  - [Recommended order (NotReady nodes)](#recommended-order-notready-nodes)
  - [What we ran](#what-we-ran)
- [Orphaned pods after `oc delete node`](#orphaned-pods-after-oc-delete-node)
- [Verify cleanup](#verify-cleanup)
- [Re-adding the same hosts](#re-adding-the-same-hosts)
- [What cannot be undone](#what-cannot-be-undone)
- [Related](#related)

---

## Context

Three Dell R660 workers in the `e21` rack were unhealthy for ~67 days:

| Node | State | Role |
|------|--------|------|
| `e21-h24-000-r660` | `NotReady`, `SchedulingDisabled` | worker |
| `e21-h26-000-r660` | `NotReady`, `SchedulingDisabled` | worker |
| `e21-h27-000-r660` | `NotReady`, `SchedulingDisabled` | worker |

`SchedulingDisabled` means the nodes were already cordoned. `NotReady` means the
kubelet was not reporting (hardware failure, network, or host down).

Commands were run from bastion `d20-h07-000-r650`.

## Pre-removal checks

### Node state

```bash
oc get nodes -o wide | grep -E 'e21-h24|e21-h26|e21-h27'
```

### Machine API

Workers on this cluster are **not** managed by the Machine API — there is no
`Machine` object to delete and no `MachineSet` to scale down.

```bash
oc get machine -n openshift-machine-api -o wide | grep -E 'e21-h24|e21-h26|e21-h27'
# (no output)
```

Removal path: `oc delete node` (manual/UPI bare metal), not `oc delete machine`.

### ODF / storage pods on the nodes

Before removal, only **RBD CSI nodeplugin** DaemonSet pods were on these nodes —
no `rook-ceph-osd`, mon, or mgr pods. That meant no OSD PDB / drain deadlock risk
for this specific removal.

```bash
oc get pods -n openshift-storage -o wide | grep -E 'e21-h24|e21-h26|e21-h27'
```

Example pods (all DaemonSet CSI plugins):

| Pod | Node |
|-----|------|
| `openshift-storage.rbd.csi.ceph.com-nodeplugin-dl8nl` | `e21-h24-000-r660` |
| `openshift-storage.rbd.csi.ceph.com-nodeplugin-zzs4x` | `e21-h26-000-r660` |
| `openshift-storage.rbd.csi.ceph.com-nodeplugin-tlwww` | `e21-h27-000-r660` |
| `openshift-storage.rbd.csi.ceph.com-nodeplugin-csi-addons-*` | (same three nodes) |

If OSD pods had been present, plan for Ceph rebalance and PDB constraints before
forcing removal. See [odf-pdb-vs-mcp-drain.md](../../troubleshooting/storage/odf-pdb-vs-mcp-drain.md).

## Remove nodes from the cluster

### Recommended order (NotReady nodes)

For `NotReady` nodes, normal drain often times out. Prefer this order:

```bash
NODES="e21-h24-000-r660 e21-h26-000-r660 e21-h27-000-r660"

for n in $NODES; do
  oc adm drain "$n" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --force \
    --grace-period=0 \
    --timeout=300s
done

for n in $NODES; do
  oc delete node "$n"
done
```

`--ignore-daemonsets` skips CSI nodeplugin pods (expected). Evicting non-DaemonSet
workloads first avoids orphaned pod objects in etcd.

### What we ran

We deleted the node objects directly (without drain first):

```bash
oc delete node e21-h24-000-r660
oc delete node e21-h26-000-r660
oc delete node e21-h27-000-r660
```

Output:

```text
node "e21-h24-000-r660" deleted
node "e21-h26-000-r660" deleted
node "e21-h27-000-r660" deleted
```

Nodes disappeared from `oc get nodes`. CSI nodeplugin pods remained as orphans
(see below).

## Orphaned pods after `oc delete node`

Deleting a node without draining leaves pods in etcd that still reference the
removed `spec.nodeName`.

```bash
oc get pods -n openshift-storage -o wide | grep -E 'e21-h24|e21-h26|e21-h27'
```

Force-delete orphaned CSI pods:

```bash
oc delete pod -n openshift-storage \
  openshift-storage.rbd.csi.ceph.com-nodeplugin-csi-addons-6d47c \
  openshift-storage.rbd.csi.ceph.com-nodeplugin-csi-addons-vq5v9 \
  openshift-storage.rbd.csi.ceph.com-nodeplugin-csi-addons-w98lt \
  openshift-storage.rbd.csi.ceph.com-nodeplugin-dl8nl \
  openshift-storage.rbd.csi.ceph.com-nodeplugin-tlwww \
  openshift-storage.rbd.csi.ceph.com-nodeplugin-zzs4x \
  --grace-period=0 --force
```

Check other namespaces for leftovers:

```bash
oc get pods -A -o wide | grep -E 'e21-h24|e21-h26|e21-h27'
```

Healthy workers continue to run CSI nodeplugins via DaemonSet; only ghost pods on
deleted node names need manual cleanup.

## Verify cleanup

```bash
oc get nodes | grep -E 'e21-h24|e21-h26|e21-h27'          # empty
oc get pods -n openshift-storage -o wide | grep -E 'e21-h24|e21-h26|e21-h27'  # empty
oc get csr | grep -E 'e21-h24|e21-h26|e21-h27'             # remove stale CSRs if any
```

If a worker `MachineConfigPool` rollout was stuck on cordoned nodes, confirm MCP
progress after node deletion:

```bash
oc get mcp worker
oc describe mcp worker | tail -30
```

Decommission the physical R660 hosts outside OpenShift (power off, inventory).

## Re-adding the same hosts

`oc delete node` cannot be undone, but the **same physical machines** can re-join
with the same hostnames if hardware is repaired.

1. Fix hardware and network on each R660.
2. Extract current worker ignition from the cluster:

   ```bash
   oc extract -n openshift-machine-api secret/worker-user-data-managed \
     --keys=userData --to=- | base64 -d > worker.ign
   ```

   If that secret is missing, list alternatives:

   ```bash
   oc get secret -n openshift-machine-api | grep worker
   ```

3. Boot or reinstall RHCOS with `worker.ign` (PXE, ISO, or
   `coreos.inst.ignition_url=...`).
4. Approve pending node client CSRs:

   ```bash
   oc get csr
   oc adm certificate approve <csr-name>
   ```

5. Wait for nodes `Ready`; MCP applies worker configs automatically.
6. CSI nodeplugins redeploy via DaemonSet on each new node.
7. Re-apply zone / topology labels if missing — compare with a healthy peer:

   ```bash
   oc get node <healthy-worker> --show-labels
   oc get nodes -L topology.kubernetes.io/zone
   ```

No `Machine` objects are created (cluster has no Machine API for these workers).
No OSD recovery was needed for this incident — these nodes never hosted Ceph OSDs.

## What cannot be undone

| Item | Recoverable? |
|------|----------------|
| Deleted `Node` API objects | No — must re-register hosts |
| Pods that were on those nodes | No — workloads do not auto-restore |
| Physical servers | Yes — `oc delete node` does not wipe disks/OS |
| Same node names in cluster | Yes — re-join with matching hostnames |
| Cluster health | Yes — three CSI-only workers are low risk to remove |

## Related

- [odf-pdb-vs-mcp-drain.md](../../troubleshooting/storage/odf-pdb-vs-mcp-drain.md) — drain / PDB behavior when nodes host OSDs
- [high-scale-config-notes.md](./high-scale-config-notes.md) — fleet ODF and worker tuning
- Red Hat: [Adding worker nodes to a user-provisioned cluster](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/postinstallation_configuration/post-install-configuration#adding-worker-nodes-to-a-user-provisioned-cluster)
