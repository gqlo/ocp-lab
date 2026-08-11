# ODF / Rook PDBs vs MCP `maxUnavailable` (node drain)

**Last Updated:** 2026-08-11

Lab notes from a stuck worker MachineConfig rollout on a large ODF cluster
(~222 OSDs, 1 OSD per node, replica 3 / failure domain `zone`).

## Lesson (short)

Drain cannot finish until Ceph OSD/mon pods are allowed to evict, and their PDBs
only permit one disruption at a time. MCP `maxUnavailable` only controls how many
nodes are cordoned in parallel — it does **not** raise the Ceph PDB limit. Setting
it to **40** makes things worse: many drains wait on one Pending pinned OSD/mon and
hit the 1h drain timeout.

## Two different knobs

| Knob | Where | What it controls |
|------|--------|------------------|
| MCP `spec.maxUnavailable` | `MachineConfigPool` `worker` | How many workers MCO may cordon/update at once |
| Rook OSD/mon PDBs | `openshift-storage` | How many **OSD** or **mon** pods may be voluntarily disrupted |

```bash
oc get mcp worker -o jsonpath='maxUnavailable={.spec.maxUnavailable}{"\n"}'
oc get pdb -n openshift-storage
```

Typical ODF PDBs (independent of each other):

| PDB | Typical `maxUnavailable` | Scope |
|-----|--------------------------|--------|
| `rook-ceph-osd` | `1` | All OSD pods (default / idle phase) |
| `rook-ceph-mon-pdb` | `1` | Mon pods |
| `rook-ceph-mgr-pdb` | `1` | Mgr pods |

**Not** one shared budget of 1 across all three. Each PDB is enforced separately.
Evicting an OSD only checks the OSD PDB; evicting a mon only checks the mon PDB.

`ALLOWED DISRUPTIONS: 0` means **no additional voluntary eviction** for that PDB
right now — not “zero pods may be down.” If one OSD is already Pending/not Ready,
the OSD budget is already spent.

Refs:

- [Kubernetes disruptions / PDB](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/)
- [PDB API (`disruptionsAllowed`)](https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/pod-disruption-budget-v1/)
- [Rook managed OSD PDBs (design)](https://github.com/rook/rook/blob/master/design/ceph/ceph-managed-disruptionbudgets.md)

## Why Ceph pods gate the drain

OSD and mon Deployments are **hostname-pinned** (hostPath data under
`/var/lib/rook/...` on this cluster — not PVC-backed mons):

```bash
oc get deploy -n openshift-storage rook-ceph-osd-<id> \
  -o jsonpath='{.spec.template.spec.nodeSelector}{"\n"}'
oc get deploy -n openshift-storage rook-ceph-mon-a \
  -o jsonpath='{.spec.template.spec.nodeSelector}{"\n"}'
# → kubernetes.io/hostname: <that-node>
```

`oc adm drain` / MCO must evict those pods. DaemonSets are ignored; the OSD/mon
are not. Until eviction succeeds, the node drain does not complete → no clean
reboot/update finish.

Mon-a may also have required node affinity for
`cluster.ocs.openshift.io/openshift-storage` plus a storage taint toleration; the
**hostname selector** is what prevents scheduling on any other Ready node.

## The Pending trap

```text
1. Cordon node A (MCO or oc adm cordon)
2. Evict OSD-A  →  uses the one OSD PDB slot (ALLOWED → 0)
3. Replacement must run on A (nodeSelector)
4. A still unschedulable → OSD-A stays Pending
5. ALLOWED stays 0 → cannot evict OSDs on other cordoned nodes
6. Those drains retry until “failed to drain after 1 hour”
```

Same pattern for mon-a on its home node (separate mon PDB).

Find who holds the budget:

```bash
oc get pdb -n openshift-storage
oc get pods -n openshift-storage -l app=rook-ceph-osd --field-selector=status.phase=Pending -o wide
oc get pods -n openshift-storage -l app=rook-ceph-mon --field-selector=status.phase!=Running -o wide

# Pending OSD → home node
oc get deploy -n openshift-storage rook-ceph-osd-<id> \
  -o jsonpath='{.spec.template.spec.nodeSelector.kubernetes\.io/hostname}{"\n"}'
oc get node <hostname>
```

Break the trap: **uncordon the Pending pod’s home** so it becomes Running/Ready,
then `ALLOWED` can return to 1.

`oc adm uncordon` alone does **not** mark the MachineConfig update done. If
`currentConfig ≠ desiredConfig` and the MCP is not paused, MCO will **re-cordon**
the node and drain again (mon-a “keeps Pending”).

## Why `maxUnavailable: 40` is not helping

MCO with 40:

- Cordons ~40 nodes and starts ~40 drains together.
- Non-PDB pods on those nodes can leave in parallel (that part is faster).
- OSD PDB still allows only **one** OSD eviction.

Then:

- First OSD eviction → Pending on still-cordoned home → `ALLOWED: 0`.
- Other ~39 drains block on OSD eviction → 1h timeout → Degraded.
- Often the update never uncordons cleanly → Pending never clears → deadlock.
- If the mon’s node is in the batch, mon PDB hits 0 too (node with mon **and** OSD needs **both** PDBs).

`maxUnavailable: 5` can look fine because the blast radius is small: a few waiters
often get the slot after the first node reboots within the 1h window. **40** creates
enough waiters and failed drains that the Pending trap locks progress.

MCP 40 does **not** mean “40 OSDs may go down.”

## Rook “dynamic” OSD PDBs (already on ODF)

Enabled when:

```bash
oc get cephcluster -n openshift-storage \
  -o jsonpath='{.items[0].spec.disruptionManagement}{"\n"}'
# managePodBudgets: true
```

Idle / stuck phase — what you usually see:

```text
rook-ceph-osd   maxUnavailable=1
```

After a clean drain starts and an OSD is down in one failure domain, Rook may
**delete** the default PDB and create **blocking** PDBs on other domains
(`rook-ceph-osd-zone-zone2`, …) so more OSDs in the draining zone can go down.
When healthy, it restores the default PDB.

Seeing only `rook-ceph-osd` with `ALLOWED: 0` means you are still in the default
phase (or stuck before unlock) — not that dynamic PDBs are disabled.

Confirm pools use zone (strictest pool wins for PDB domain):

```bash
oc get cephblockpool -n openshift-storage \
  -o custom-columns=NAME:.metadata.name,FD:.spec.failureDomain,SIZE:.spec.replicated.size
```

There is **no** CephCluster field to set default OSD `maxUnavailable` to 5/15.
Hand-editing PDBs while `managePodBudgets: true` is **unsupported** — the operator
may reconcile them back. Lasting custom budgets require `managePodBudgets: false`
(loses Rook’s zone-aware blocking PDBs).

## Lab change: manually raised PDB budgets (2026-08-11)

To unblock / speed the stuck MCO drain, PDBs were patched by hand (Rook management
still **on** — may revert on reconcile):

| PDB | Default | Patched to | Notes |
|-----|---------|------------|--------|
| `rook-ceph-osd` | `1` | **`15`** | Aligns better with MCP batch; not an official knob |
| `rook-ceph-mon-pdb` | `1` | **`3`** | With only **3** mons, allows all mons disrupted (quorum risk) |
| `rook-ceph-mgr-pdb` | `1` | **`2`** | With only **2** mgrs, allows both disrupted (no standby) |

Commands used:

```bash
# OSD
oc patch pdb rook-ceph-osd -n openshift-storage --type=merge \
  -p '{"spec":{"maxUnavailable":15}}'

# Mon (3 mons on this cluster)
oc patch pdb rook-ceph-mon-pdb -n openshift-storage --type=merge \
  -p '{"spec":{"maxUnavailable":3}}'

# Mgr (2 mgrs: rook-ceph-mgr-a / rook-ceph-mgr-b)
oc patch pdb rook-ceph-mgr-pdb -n openshift-storage --type=merge \
  -p '{"spec":{"maxUnavailable":2}}'
```

Verify:

```bash
oc get pdb -n openshift-storage
# Expect something like:
# rook-ceph-mgr-pdb   maxUnavailable=2
# rook-ceph-mon-pdb   maxUnavailable=3
# rook-ceph-osd       maxUnavailable=15
```

Check whether Rook still owns management:

```bash
oc get cephcluster -n openshift-storage \
  -o jsonpath='{.items[0].spec.disruptionManagement}{"\n"}'
# managePodBudgets: true  → patches may be overwritten later
```

If values snap back to `1`, either re-patch or (lab only):

```bash
oc patch cephcluster ocs-storagecluster-cephcluster -n openshift-storage --type=merge -p '
{
  "spec": {
    "disruptionManagement": {
      "managePodBudgets": false
    }
  }
}'
# then re-apply the PDB patches above
```

Restore defaults when the rollout is done (safer for production-like behavior):

```bash
oc patch pdb rook-ceph-osd -n openshift-storage --type=merge \
  -p '{"spec":{"maxUnavailable":1}}'
oc patch pdb rook-ceph-mon-pdb -n openshift-storage --type=merge \
  -p '{"spec":{"maxUnavailable":1}}'
oc patch pdb rook-ceph-mgr-pdb -n openshift-storage --type=merge \
  -p '{"spec":{"maxUnavailable":1}}'
# if you disabled managePodBudgets, set it back to true
```

## Practical recovery

```bash
# 1) Stop the siege
oc patch mcp worker --type=merge -p '{"spec":{"paused":true,"maxUnavailable":1}}'

# 2) Free PDB budgets — uncordon homes of Pending mon/OSD
oc adm uncordon <osd-home> <mon-home>

# 3) Wait until pods Ready and PDB ALLOWED >= 1
oc get pdb -n openshift-storage
oc get pods -n openshift-storage -l 'app in (rook-ceph-osd,rook-ceph-mon)' | grep -v Running

# 4) Optional: uncordon leftover SchedulingDisabled workers
oc get nodes --no-headers | awk '/SchedulingDisabled/{print $1}' | xargs -r oc adm uncordon

# 4.1) List still-cordoned nodes (unschedulable=true) with zone
oc get nodes -o custom-columns=NAME:.metadata.name,UNSCHEDULABLE:.spec.unschedulable,ZONE:.metadata.labels.topology\\.kubernetes\\.io/zone --no-headers | awk '$2=="true"'

# 5) Resume with low parallelism
oc patch mcp worker --type=merge -p '{"spec":{"paused":false}}'
```

Watch progress:

```bash
oc get mcp worker
oc get nodes | grep -c SchedulingDisabled
oc get pdb -n openshift-storage
```

Healthy serial pattern: one node `NotReady` (reboot), OSD PDB `ALLOWED` flips
`0 → 1 → 0`, `UPDATEDMACHINECOUNT` climbs.

## Guidance for this fleet

| MCP `maxUnavailable` | Fit |
|----------------------|-----|
| **1** | Safest match for default Rook OSD PDB |
| **~5** | Often OK if same-zone and drains finish within 1h (matches ~5 parallel drains in high-scale notes) |
| **40** | Avoid on OSD-per-node workers — recreates the Pending trap |

Same zone / 3 zones makes losing many OSDs in **one** zone less dangerous for
cross-zone replica loss than draining two zones, but it does **not** mean 40
parallel OSD evictions are safe or allowed by the default PDB.

## Related

- [Rook ceph-managed-disruptionbudgets.md](https://github.com/rook/rook/blob/master/design/ceph/ceph-managed-disruptionbudgets.md)
- [High-scale ODF / drain notes](../ocp-admin/high-scale-config-notes.md) (~5 parallel drains)
