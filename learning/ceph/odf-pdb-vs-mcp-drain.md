# ODF / Rook PDBs vs MCP `maxUnavailable` (node drain)

**Last Updated:** 2026-08-12 (MCO zone-order reboot notes)

Lab notes from a stuck worker MachineConfig rollout on a large ODF cluster
(~222 OSDs, 1 OSD per node, replica 3 / failure domain `zone`).

## Catalog

- [Lesson (short)](#lesson-short)
- [Two different knobs](#two-different-knobs)
- [MCO reboot / drain rollout](#mco-reboot--drain-rollout)
  - [Trigger a worker-pool reboot (rolling)](#trigger-a-worker-pool-reboot-rolling)
  - [Zone ordering (MCO is zone-aware)](#zone-ordering-mco-is-zone-aware)
  - [Single-node drain / reboot / uncordon](#single-node-drain--reboot--uncordon)
- [Why Ceph pods gate the drain](#why-ceph-pods-gate-the-drain)
- [Why `maxUnavailable: 40` is not helping](#why-maxunavailable-40-is-not-helping)
- [Rook “dynamic” OSD PDBs (already on ODF)](#rook-dynamic-osd-pdbs-already-on-odf)
  - [Rook operator log level (DEBUG)](#rook-operator-log-level-debug)
- [Lab change: manually raised PDB budgets (2026-08-11)](#lab-change-manually-raised-pdb-budgets-2026-08-11)
- [Incident note: final stuck node](#incident-note-final-stuck-node)
- [Guidance for this fleet](#guidance-for-this-fleet)
- [Related](#related)
- [Refs](#refs)

---

## Lesson (short)

Drain cannot finish until Ceph OSD/mon pods are allowed to evict. MCP
`maxUnavailable` only controls how many nodes are cordoned in parallel — it does
**not** raise Ceph disruption budgets.

With ODF pools using failure domain `zone`, Rook should create zone-scoped OSD PDBs
during disruption handling (for example `rook-ceph-osd-zone-<zone>`). In this lab
incident, those zone PDBs were **not** created after we manually patched the global
OSD PDB (`rook-ceph-osd`), so drain behavior stayed tied to the global PDB path.

If the cluster is stuck in the default/idle phase (`rook-ceph-osd` budget consumed),
setting MCP to **40** makes things worse: many drains wait on one Pending pinned
OSD/mon and hit the 1h drain timeout.

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

## MCO reboot / drain rollout

### Trigger a worker-pool reboot (rolling)

```bash
oc adm reboot-machine-config-pool mcp/worker
```

Watch progress:

```bash
oc get mcp worker
oc get mcn -n openshift-machine-config-operator

# Cordoned nodes (SchedulingDisabled) with zone label
oc get nodes -L topology.kubernetes.io/zone | grep -i SchedulingDisabled
```

### Zone ordering (MCO is zone-aware)

MCO does **not** pick nodes at random. After a machine config change it updates
nodes in this order ([Red Hat machine configuration docs](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/machine_configuration/mco-coreos-layering)):

1. **Alphabetically by `topology.kubernetes.io/zone`** (e.g. `zone1` → `zone2` → `zone3`)
2. **Oldest nodes first** within each zone
3. Up to **`maxUnavailable`** nodes in parallel per batch

With `maxUnavailable: 1`, rollout is effectively **one zone at a time** (starting
with the alphabetically first zone). With `maxUnavailable: 5` on this fleet (~70+
nodes per zone), early batches usually stay within the current zone; a batch can
**spill into the next zone** only if fewer nodes remain in the current zone than
`maxUnavailable`.

MCO zone ordering is independent of Rook/Ceph PDB limits — Ceph can still block
individual drains even when MCO has cordoned the “right” zone-ordered node.

Check zone labels and rollout order:

```bash
oc get nodes -l node-role.kubernetes.io/worker= \
  -L topology.kubernetes.io/zone --no-headers | sort -k2,2 -k1,1

oc get mcp worker -o jsonpath='maxUnavailable={.spec.maxUnavailable}{"\n"}'

oc get mcn -n openshift-machine-config-operator \
  -o custom-columns=NAME:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,UPDATED:.status.conditions[?(@.type==\"Updated\")].status

# Currently cordoned nodes with zone (after drain or during MCO rollout)
oc get nodes -L topology.kubernetes.io/zone | grep -i SchedulingDisabled
```

### Single-node drain / reboot / uncordon

```bash
# Drain one node (leaves it SchedulingDisabled until uncordoned)
oc adm drain e40-h28-000-r650 \
  --ignore-daemonsets --delete-emptydir-data --grace-period=300 --timeout=1h

# Reboot without SSH (after drain)
oc debug node/e40-h28-000-r650 -- chroot /host reboot

# Or all-in-one (if supported on your OCP version)
oc adm reboot-node e40-h28-000-r650

# Re-enable scheduling when done
oc adm uncordon e40-h28-000-r650
```

`oc adm drain` and MCO-managed drains **do not** auto-uncordon when finished.

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
enough waiters and failed drains that progress stalls.

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
**delete** the default PDB and create zone PDBs (`rook-ceph-osd-zone-zone2`, …).
This is the expected behavior for zone failure domains.

Important clarification: by default we do **not** set a custom per-zone
`maxUnavailable` for these zone PDBs. They are generated and managed by Rook based
on cluster state, then removed/restored as health recovers.

What happened here: after manually patching the global OSD PDB (`rook-ceph-osd`),
Rook did not create the expected `rook-ceph-osd-zone-*` PDBs, so updates continued
to depend on the global PDB budget only.

### Rook operator log level (DEBUG)

Check current level (`ROOK_LOG_LEVEL` missing → default **INFO**):

```bash
kubectl -n openshift-storage get configmap rook-ceph-operator-config \
  -o jsonpath='{.data.ROOK_LOG_LEVEL}{"\n"}'
```

Enable DEBUG during investigation:

```bash
kubectl -n openshift-storage patch configmap rook-ceph-operator-config --type merge \
  -p '{"data":{"ROOK_LOG_LEVEL":"DEBUG"}}'
```

Revert when done (remove the key so it returns to default INFO):

```bash
kubectl -n openshift-storage patch configmap rook-ceph-operator-config --type json \
  -p '[{"op":"remove","path":"/data/ROOK_LOG_LEVEL"}]'
```

Or set INFO explicitly:

```bash
kubectl -n openshift-storage patch configmap rook-ceph-operator-config --type merge \
  -p '{"data":{"ROOK_LOG_LEVEL":"INFO"}}'
```

Additional operator debug logs are needed to fully explain why zone PDB behavior
did not transition as expected in this scenario.

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

## Incident note: final stuck node

During this incident, several workers remained `SchedulingDisabled` late in the
rollout, mostly in `zone3` (with one in `zone2`), for example:

```text
NAME               ZONE    SCHED_DISABLED
e40-h28-000-r650   zone2   true
e40-h34-000-r650   zone3   true
e40-h37-000-r650   zone3   true
e41-h01-000-r650   zone3   true
e41-h02-000-r650   zone3   true
e41-h05-000-r650   zone3   true
e41-h06-000-r650   zone3   true
e41-h07-000-r650   zone3   true
e41-h09-000-r650   zone3   true
e41-h10-000-r650   zone3   true
e41-h11-000-r650   zone3   true
e41-h13-000-r650   zone3   true
e41-h15-000-r650   zone3   true
e42-h28-000-r650   zone3   true
e42-h29-000-r650   zone3   true
```

The **last** node that remained stuck was due to a hardware fault, not ODF PDB
logic:

```text
A fatal error was detected on a component at bus 151 device 2 function 0.
Tue Aug 11 2026 20:13:35
```

This should be treated as a node hardware remediation path separate from Ceph/Rook
PDB behavior.

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
- [MCO node update ordering by zone (PR #3009)](https://github.com/openshift/machine-config-operator/pull/3009)

## Refs

- [Kubernetes disruptions / PDB](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/)
- [PDB API (`disruptionsAllowed`)](https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/pod-disruption-budget-v1/)
- [Rook managed OSD PDBs (design)](https://github.com/rook/rook/blob/master/design/ceph/ceph-managed-disruptionbudgets.md)
- [OpenShift MCO node update order (alphabetical by zone, oldest first)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/machine_configuration/mco-coreos-layering)
