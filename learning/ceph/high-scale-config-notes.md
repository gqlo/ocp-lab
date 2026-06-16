# High-Scale Cluster Config Notes

Operational tweaks and queries for the CNV high-scale / ODF test cluster. See also
[cnv-highscale-test-plan.md](./cnv-highscale-test-plan.md).

## Table of contents

- [Monitoring](#monitoring)
  - [Prometheus config](#prometheus-config)
    - [On-disk layout (inside pod)](#on-disk-layout-inside-pod)
    - [TSDB block dates and sizes](#tsdb-block-dates-and-sizes)
  - [Prometheus DB growth (PromQL)](#prometheus-db-growth-promql)
  - [Monitoring alerts](#monitoring-alerts)
- [OpenShift Data Foundation](#openshift-data-foundation)
  - [CSI Addons controller manager (memory)](#csi-addons-controller-manager-memory)
  - [OCS metrics exporter (memory)](#ocs-metrics-exporter-memory)
  - [OSD CPU and memory](#osd-cpu-and-memory)
  - [Ceph block pool PG tuning](#ceph-block-pool-pg-tuning)
  - [ODF alerts](#odf-alerts)
- [Kube Descheduler & CNV](#kube-descheduler--cnv)
  - [Descheduler eviction limits](#descheduler-eviction-limits)
  - [CNV live migration limits (HCO)](#cnv-live-migration-limits-hco)

---

## Monitoring

### Prometheus config

Live `cluster-monitoring-config` (`openshift-monitoring`):

```yaml
prometheusK8s:
  retention: 90d   # lower if prometheusdb PVC fills (e.g. 30d, 14d)
  retentionSize: 1400GB   # cap TSDB+WAL; deletes oldest blocks first (~80% of 1700Gi PVC)
  volumeClaimTemplate:
    metadata:
      name: prometheusdb
    spec:
      storageClassName: localfile
      volumeMode: Filesystem
      resources:
        requests:
          storage: 1700Gi
```

PVCs: `prometheusdb-prometheus-k8s-0`, `prometheusdb-prometheus-k8s-1`.

#### On-disk layout (inside pod)

```bash
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  sh -c 'df -h /prometheus; echo ---; du -sh /prometheus/* 2>/dev/null | sort -h'
```

Do not manually delete TSDB block dirs or WAL while Prometheus is running.

#### TSDB block dates and sizes

Each block directory under `/prometheus/` is named with a [ULID](https://github.com/ulid/spec).
The first 10 characters encode the block **creation** time (Unix ms, Crockford base32).
That is when the block was cut or compaction finished — not necessarily the full metrics
time range inside it (use `meta.json` `minTime`/`maxTime` for that).

Block size on disk is **not** correlated with recency: a 345G dir can be weeks old while
today's 2h blocks may be ~7G each.

List blocks with creation date and size (sorted oldest → newest):

```bash
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  sh -c 'du -sh /prometheus/* 2>/dev/null | sort -h' | python3 <(cat <<'PY'
import datetime, re, sys

CROCK = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

def ulid_created(ulid):
    ts = 0
    for c in ulid[:10].upper():
        ts = ts * 32 + CROCK.index(c)
    return datetime.datetime.fromtimestamp(ts / 1000, tz=datetime.timezone.utc)

def parse_du_line(line):
    m = re.match(r"^(\S+)\s+.*?([0-9A-HJKMNP-TV-Z]{26})\s*$", line.strip(), re.I)
    return (m.group(2).upper(), m.group(1)) if m else None

rows = []
for line in sys.stdin:
    parsed = parse_du_line(line)
    if not parsed:
        continue
    ulid, size = parsed
    rows.append((ulid_created(ulid), ulid, size))

rows.sort(key=lambda r: r[0])

print(f"{'Created (UTC)':<20} {'Size':>8}  Block ULID")
print("-" * 62)
for created, ulid, size in rows:
    print(f"{created.strftime('%Y-%m-%d %H:%M:%S'):<20} {size:>8}  {ulid}")
PY
)
```

Non-block paths (`wal/`, `chunks_head/`, `lock`, etc.) are skipped automatically.

**Shell pitfall:** `oc exec ... | python3 - <<'PY'` does not work — the heredoc replaces
stdin, so Python never sees the `du` output. Use process substitution (`python3 <(cat <<'PY'`)
as above, or capture first:

```bash
DU=$(oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  sh -c 'du -sh /prometheus/* 2>/dev/null | sort -h')
printf '%s\n' "$DU" | python3 <<'PY'
# ... same Python as above ...
PY
```

Sample metrics time range for one block:

```bash
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  cat /prometheus/01KR80M2987BSN6NM4BNAHQKHZ/meta.json
```

### Prometheus DB growth (PromQL)

```promql
prometheus_tsdb_storage_blocks_bytes{
  namespace="openshift-monitoring",
  pod="prometheus-k8s-0"
}
```

### Monitoring alerts

| Alert | Typical action |
|-------|----------------|
| `PersistentVolumeFillingUp` (`prometheusdb-*`) | Check TSDB query above; lower `retention`, set `retentionSize`, or expand PVC |

---

## OpenShift Data Foundation

### CSI Addons controller manager (memory)

Fixes `CrashLoopBackOff` on `csi-addons-controller-manager` when the default memory
limit is too low under load. Patch the **Deployment**, not the pod.

Namespace is usually `openshift-storage` (confirm with `oc get pod -A | grep csi-addons`).

```bash
oc patch deployment csi-addons-controller-manager -n openshift-storage --type=json -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "2G"}
]'
```

### OCS metrics exporter (memory)

The `ocs-metrics-exporter` pod was frequently OOM-killed under high-scale load.
Patch the **Deployment** memory limit to **512M** (not the pod).

```bash
oc patch deployment ocs-metrics-exporter -n openshift-storage --type=json -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "2G"}
]'
```

The pod runs **3/3** containers; if OOM persists, apply the same patch to
`/containers/1/...` and `/containers/2/...`, or patch by container name via
`oc edit deployment ocs-metrics-exporter -n openshift-storage`. OCS may reconcile
and revert manual patches on upgrade.

### OSD CPU and memory

Preferred: patch the **StorageCluster** so the OCS operator rolls OSD pods with new
limits. Adjust CPU/memory to match node capacity and load.

```bash
# Current OSD resource settings
oc get storagecluster ocs-storagecluster -n openshift-storage \
  -o jsonpath='{.spec.resources.osd}{"\n"}' | jq .

# Example high-scale bump (edit limits/requests as needed)
oc patch storagecluster ocs-storagecluster -n openshift-storage --type=merge -p '
{
  "spec": {
    "resources": {
      "osd": {
        "limits": {
          "cpu": "5",
          "memory": "24Gi"
        },
        "requests": {
          "cpu": "4",
          "memory": "16Gi"
        }
      }
    }
  }
}'
```

### Ceph block pool PG tuning

High-scale cluster: **90 nodes**, **1 OSD per node** (2.9 TiB NVMe), replica **3**.
VM block volumes use pool `ocs-storagecluster-cephblockpool` (RBD / `ocs-storagecluster-ceph-rbd`).

We run **~5 node drains in parallel** during maintenance. More PGs split recovery into
smaller parallel backfill jobs across the remaining OSDs. **4096 PGs** targets ~**137 PG
instances per OSD** `(4096 × 3 / 90)` — near the usual ~100/OSD guideline for replica 3.

Disable ODF PG autoscaling first so the operator does not revert manual `pg_num` / `pgp_num`.

Run from the **rook-ceph-tools** pod (`openshift-storage`):

```bash
oc rsh -n openshift-storage deploy/rook-ceph-tools
```

Check current pool settings:

```bash
ceph osd pool get ocs-storagecluster-cephblockpool all
ceph osd pool autoscale-status
```

Apply (order matters: autoscale off, then set counts):

```bash
ceph osd pool set ocs-storagecluster-cephblockpool pg_autoscale_mode off
ceph osd pool set ocs-storagecluster-cephblockpool pgp_num 4096
ceph osd pool set ocs-storagecluster-cephblockpool pg_num 4096
```

| Setting | Value | Role |
|---------|-------|------|
| `pg_autoscale_mode` | `off` | Stops ODF autoscaler from changing PG counts |
| `pg_num` | `4096` | Planned PG count for the pool |
| `pgp_num` | `4096` | PGs CRUSH actually uses for placement (`pgp_num` ≤ `pg_num`) |

**Note:** `pgp_num` cannot exceed `pg_num`. If the pool is well below 4096 today, raise
`pg_num` first (Ceph often recommends doubling until the target), then set `pgp_num` to
match. Setting both to 4096 in one step is fine when `pg_num` is already at or near 4096.

Verify and watch rebalance:

```bash
ceph osd pool get ocs-storagecluster-cephblockpool pg_num
ceph osd pool get ocs-storagecluster-cephblockpool pgp_num
ceph osd pool get ocs-storagecluster-cephblockpool pg_autoscale_mode
ceph -s
ceph pg stat
```

Expect **misplaced objects** and PG states such as `backfill_wait` / `backfilling` while
PGs split or remap — same class of activity as after an OSD event. Prefer a maintenance
window; client IO stays up but recovery load rises.

One-liner from the host (no interactive rsh):

```bash
oc exec -n openshift-storage deploy/rook-ceph-tools -- \
  ceph osd pool get ocs-storagecluster-cephblockpool all
```

### ODF alerts

| Alert | Typical action |
|-------|----------------|
| `csi-addons-controller-manager` CrashLoop | Patch deployment memory (see above) |
| `ocs-metrics-exporter` OOMKilled | Patch deployment memory to 512M (see above) |
| Ceph slow / `PausedIOError` on VMs | Check `ceph status`, OSD pods on affected node |
| PG backfill after `pg_num` change | Normal during rebalance; watch `ceph -s` until `active+clean` |

---

## Kube Descheduler & CNV

Descheduler eviction limits and CNV live-migration concurrency should match so KubeVirt can
execute every eviction the descheduler requests in a cycle. HCO defaults are **5** cluster /
**2** per node; high-scale uses **50** / **10** (same as descheduler `total` / `node`).

| Descheduler (`KubeDescheduler`) | CNV (`HyperConverged` under `spec.virtualization`) |
|---------------------------------|-----------------------------------------------------|
| `evictionLimits.node: 10` | `liveMigrationConfig.parallelOutboundMigrationsPerNode: 10` |
| `evictionLimits.total: 50` | `liveMigrationConfig.parallelMigrationsPerCluster: 50` |
| `deschedulingIntervalSeconds: 60` | `workloadUpdateStrategy.batchEvictionInterval: 1m0s` (default) |
| per-node eviction cap | `workloadUpdateStrategy.batchEvictionSize: 10` (default) |

Also required for descheduler-driven migrations: `evictionStrategy: LiveMigrate` on the HCO
(default on high-scale clusters) and on VMIs.

### Descheduler eviction limits

Patch the **KubeDescheduler** CR (not the descheduler Deployment).

```bash
# Current eviction limits
oc get kubedescheduler cluster -n openshift-kube-descheduler-operator \
  -o jsonpath='{.spec.evictionLimits}{"\n"}' | jq .

# Patch eviction limits (node=10, total=50)
oc patch kubedescheduler cluster -n openshift-kube-descheduler-operator --type=merge -p '
{
  "spec": {
    "evictionLimits": {
      "node": 10,
      "total": 50
    }
  }
}'
```

Equivalent via `monitoring/scripts/ocp-patch.sh`: `ocp-patch.sh desched 10 50`.

### CNV live migration limits (HCO)

Patch the **HyperConverged** CR (`hco kubevirt-hyperconverged` in `openshift-cnv`), not the
KubeVirt CR. On current CNV builds, migration settings live under `spec.virtualization`
(not top-level `spec.liveMigrationConfig`).

```bash
# Current live-migration concurrency
oc get hco kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.virtualization.liveMigrationConfig}{"\n"}' | jq .

# Align with descheduler (cluster=50, outbound per node=10)
oc patch hco kubevirt-hyperconverged -n openshift-cnv --type=merge -p '
{
  "spec": {
    "virtualization": {
      "liveMigrationConfig": {
        "parallelMigrationsPerCluster": 50,
        "parallelOutboundMigrationsPerNode": 10
      }
    }
  }
}'
```

Inspect or edit the full virtualization block: `oc edit hco kubevirt-hyperconverged -n openshift-cnv`.

`monitoring/scripts/ocp-patch.sh lm 50 10` patches top-level `spec.liveMigrationConfig`; on
clusters that only use `spec.virtualization`, use the patch above instead.
