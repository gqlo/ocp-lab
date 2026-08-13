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
  - [Slack alerting (Alertmanager)](#slack-alerting-alertmanager)
- [OpenShift Data Foundation](#openshift-data-foundation)
  - [Zap disks before ODF install](#zap-disks-before-odf-install)
  - [CSI Addons controller manager (memory)](#csi-addons-controller-manager-memory)
  - [OCS metrics exporter (memory)](#ocs-metrics-exporter-memory)
  - [Rook operator (memory)](#rook-operator-memory)
  - [OSD CPU and memory](#osd-cpu-and-memory)
  - [Ceph block pool PG tuning](#ceph-block-pool-pg-tuning)
  - [Default StorageClass for CNV](#default-storageclass-for-cnv)
  - [ODF alerts](#odf-alerts)
- [Worker KubeletConfig](#worker-kubeletconfig)
  - [highscale (`maxPods`)](#highscale-maxpods)
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

### Slack alerting (Alertmanager)

Flow: **PrometheusRule (firing) → Alertmanager → Slack Incoming Webhook**.

Alertmanager runs in `openshift-monitoring`. The webhook URL is the "API" — create it at
[api.slack.com/apps](https://api.slack.com/apps) → Create App → Incoming Webhooks ON → pick
channel. **Never commit the URL** to a public repo (no auth; anyone with the URL can post).

| What | Where |
|------|-------|
| Webhook URL | Slack app → Incoming Webhooks |
| Alertmanager config | Secret `alertmanager-main` in `openshift-monitoring` |
| Console | Administration → Cluster Settings → Configuration → Alertmanager |

**Console (quick):** cluster-admin → Alertmanager → add receiver → Slack → paste webhook URL
and channel.

**YAML (GitOps):** edit `alertmanager.yaml` in the `alertmanager-main` secret:

```yaml
global:
  slack_api_url: 'https://hooks.slack.com/services/T.../B.../XXX'

receivers:
  - name: slack-critical
    slack_configs:
      - channel: '#alerts'
        send_resolved: true
        username: 'OpenShift Alertmanager'
        color: '{{ if eq .Status "firing" }}danger{{ else }}good{{ end }}'
        title: '{{ template "slack.default.title" . }}'
        text: '{{ template "slack.default.text" . }}'

route:
  receiver: slack-critical
  routes:
    - match:
        severity: critical
      receiver: slack-critical
```

Apply:

```bash
oc -n openshift-monitoring create secret generic alertmanager-main \
  --from-file=alertmanager.yaml=alertmanager.yaml \
  --dry-run=client -o yaml | oc apply -f -
```

**ArgoCD / Sealed Secrets:** encrypt the webhook URL with Sealed Secrets and commit safely.
Annotate the existing `alertmanager-main` secret with
`sealedsecrets.bitnami.com/managed="true"` before ArgoCD overwrites it (a PreSync hook job
works well).

At high scale (~250 nodes, ~75k VMs), add route rules by `severity` and `namespace` so one
channel is not flooded — extend the `route.routes` block with additional `match` receivers.

---

## OpenShift Data Foundation

### Zap disks before ODF install

Wipe OSD disks **on each storage node** before a fresh ODF install (or when reusing
disks from a prior Ceph/ODF deployment). `wipefs` and a short `dd` zero pass are not
enough: BlueStore leaves superblock and label metadata that Local Storage Operator /
Rook can still detect, which blocks clean discovery or causes OSD prepare failures.

Use **`ceph-bluestore-tool zap-device`** from the same Ceph major image as the target
ODF release (e.g. `quay.io/ceph/ceph:v19` for ODF 4.19).

#### Preconditions

| Check | Why |
|-------|-----|
| Run on the **node that owns the disk** | The block device must be local (`oc debug` works but direct SSH is simpler for many nodes) |
| **Correct device** — not the OS disk | Double-check `lsblk`, `by-path`, and serial; high-scale workers use a dedicated NVMe for ODF |
| Disk **unmounted**, no LVM PV, no filesystem | `findmnt`, `pvs`, `lsblk -f` should show an empty raw block device |
| No OSD pod using the disk | On reinstall: remove old `StorageCluster` / `LocalVolume` / `LocalVolumeSet` first; cordon/drain if an OSD is still bound |
| Ceph image tag matches ODF | `oc get csv -n openshift-storage -o jsonpath='{.items[*].spec.version}'` or cluster docs |

Identify the ODF disk on a worker (example — adjust model/path for your hardware):

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL,SERIAL
ls -l /dev/disk/by-path/
```

Set the **whole-disk** device name (not a partition):

```bash
disk=nvme1n1   # example; must match the dedicated ODF NVMe on this node
```

#### Zap with podman on the node

OpenShift nodes already have podman and kubelet registry auth at
`/var/lib/kubelet/config.json`. Run as root on the node:

```bash
sudo /usr/bin/podman run \
  --authfile /var/lib/kubelet/config.json \
  --rm -ti \
  --privileged \
  --device /dev/$disk \
  --entrypoint ceph-bluestore-tool \
  quay.io/ceph/ceph:v19 \
  zap-device --dev /dev/$disk --yes-i-really-really-mean-it
```

Flags in short:

| Flag | Role |
|------|------|
| `--authfile /var/lib/kubelet/config.json` | Pull `quay.io/ceph/ceph` using node/kubelet credentials |
| `--privileged` + `--device /dev/$disk` | Pass the raw block device into the container |
| `--entrypoint ceph-bluestore-tool` | Run the zap helper instead of the default `ceph` entrypoint |
| `--yes-i-really-really-mean-it` | Required confirmation; **destroys all data on the device** |

Repeat on **every** storage node and **every** disk that will back OSDs.

#### Verify

On the node, the disk should show no filesystem, no BlueStore label, and no partitions:

```bash
lsblk /dev/$disk
wipefs /dev/$disk          # should print nothing
file -s /dev/$disk           # typically "data" on a clean device
```

Optional — confirm BlueStore metadata is gone (same image):

```bash
sudo /usr/bin/podman run --rm -ti --privileged --device /dev/$disk \
  --entrypoint ceph-bluestore-tool quay.io/ceph/ceph:v19 \
  show-label --dev /dev/$disk
```

Expect an error or empty output on a successfully zapped disk.

#### After zap

1. Apply `LocalVolumeSet` / storage node labels per your ODF bare-metal flow (`templates/odf/`).
2. Install or recreate the `StorageCluster` and confirm Local Storage Operator discovers devices.
3. Watch OSD prepare pods: `oc get pods -n openshift-storage -l app=rook-ceph-osd`.

**Note:** `scripts/ceph/clean_odf_disk.sh` (dd + `wipefs` via `oc debug`) is a lighter
cleanup for non-Ceph disks; prefer `ceph-bluestore-tool zap-device` when the disk ever
hosted a BlueStore OSD.

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

### Rook operator (memory)

At high scale (~240 nodes, 222 OSDs), `rook-ceph-operator` can get OOMKilled under its
default **512Mi** limit. `oc describe pod` on the operator shows:

```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

This tends to happen during a large reconcile — the previous-container logs
(`oc logs <pod> --previous`) typically show something like `N of N OSD Deployments need
update` immediately before the kill, alongside full node-topology validation across
every zone.

Unlike `csi-addons-controller-manager` / `ocs-metrics-exporter` (owned by the
`StorageCluster`), the `rook-ceph-operator` Deployment is owned by its **CSV**
(`ClusterServiceVersion`, via OLM). Patching the Deployment directly gets reverted
within seconds — patch the **CSV** instead:

```bash
# Find the active CSV name
oc get csv -n openshift-storage | grep rook-ceph-operator

# Patch memory limit on the CSV (deployment index 0 -> container index 0 —
# verify indexes if the CSV layout differs)
oc patch csv rook-ceph-operator.v4.22.0-rhodf -n openshift-storage --type=json -p='[
  {"op": "replace", "path": "/spec/install/spec/deployments/0/spec/template/spec/containers/0/resources/limits/memory", "value": "2G"}
]'
```

OLM propagates the CSV change to the Deployment and rolls a new pod automatically — no
separate rollout needed. Verify:

```bash
oc get deployment rook-ceph-operator -n openshift-storage \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}{"\n"}'

oc get pods -n openshift-storage -l app=rook-ceph-operator
```

**Caveat:** the patch lives on the version-specific CSV object
(`rook-ceph-operator.v4.22.0-rhodf`). An ODF/Rook operator upgrade installs a *new* CSV
without this patch — but `monitoring/scripts/odf-deployment-memory-watch.sh`
(`CSV_TARGETS`) now re-resolves the active `Succeeded`-phase CSV by name prefix every
cycle and re-patches it automatically, so this survives upgrades without manual
intervention as long as the watcher keeps running.

### OSD CPU and memory

Patch **`spec.storageDeviceSets[0].resources`** on the StorageCluster. The OCS operator
propagates this to the CephCluster device sets, which Rook uses for OSD pod limits.
(`spec.resources.osd` alone does not update running OSD pods on ODF 4.21.)

```bash
# High-scale bump (edit limits/requests as needed)
oc patch storagecluster ocs-storagecluster -n openshift-storage --type=json -p \
  '[{"op":"replace","path":"/spec/storageDeviceSets/0/resources","value":{"requests":{"cpu":"5","memory":"24Gi"},"limits":{"cpu":"5","memory":"24Gi"}}}]'

# Verify StorageCluster → CephCluster → Deployments → pods
oc get storagecluster ocs-storagecluster -n openshift-storage \
  -o jsonpath='{.spec.storageDeviceSets[0].resources}{"\n"}' | jq .

oc get cephcluster ocs-storagecluster-cephcluster -n openshift-storage \
  -o jsonpath='{range .spec.storage.storageClassDeviceSets[*]}{.name}{": "}{.resources}{"\n"}{end}'

oc get deploy -n openshift-storage -l app=rook-ceph-osd \
  -o custom-columns=NAME:.metadata.name,CPU:.spec.template.spec.containers[0].resources.requests.cpu,MEM:.spec.template.spec.containers[0].resources.requests.memory | head

oc get pod -n openshift-storage -l app=rook-ceph-osd \
  -o custom-columns=NAME:.metadata.name,CPU:.spec.containers[0].resources.requests.cpu,MEM:.spec.containers[0].resources.requests.memory | head
```

Propagation chain: **StorageCluster → CephCluster → OSD Deployment template → running pod**.
CephCluster can show the new limits while Deployments and pods still run **2 CPU / 5Gi** (ODF
defaults). Check Deployments, not pods alone — a rollout only recreates pods from the current
Deployment spec.

If CephCluster is correct but Deployments are stale, restart the Rook operator first:

```bash
oc rollout restart deploy/rook-ceph-operator -n openshift-storage
```

Then test one OSD. When the Deployment template shows the new limits, restart the pod:

```bash
oc rollout restart deploy/rook-ceph-osd-0 -n openshift-storage

oc get deploy rook-ceph-osd-0 -n openshift-storage \
  -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}' | jq .

oc get pod -n openshift-storage -l app=rook-ceph-osd,ceph-osd-id=0 \
  -o jsonpath='{.items[0].spec.containers[0].resources}{"\n"}' | jq .
```

#### Batched rollout (222 OSDs)

Do **not** restart all OSD Deployments at once. Roll in small batches during a maintenance
window and watch Ceph recovery between batches. At **5 CPU / 24Gi** per OSD, 222 OSDs reserve
roughly **~1,110 CPU** and **~5.3 TiB** memory cluster-wide — confirm storage nodes can
schedule the new requests before rolling everything.

List deployments (IDs may not be contiguous):

```bash
oc get deploy -n openshift-storage -l app=rook-ceph-osd -o name | wc -l

oc get deploy -n openshift-storage -l app=rook-ceph-osd -o name \
  | sed 's|deployment.apps/rook-ceph-osd-||' | sort -n
```

Restart in batches (`BATCH=10`, `PAUSE=120` — tune from `ceph -s` recovery):

```bash
BATCH=10
PAUSE=120   # seconds between batches — tune from ceph -s recovery

for id in $(seq 0 221); do
  oc rollout restart deploy/rook-ceph-osd-$id -n openshift-storage 2>/dev/null || true
  if (( (id + 1) % BATCH == 0 )); then
    echo "Restarted through osd-$id — check ceph -s"
    sleep $PAUSE
  fi
done
```

Watch cluster health during rollout (from **rook-ceph-tools**):

```bash
ceph -s
ceph pg stat
```

Spot-check progress:

```bash
oc get pod -n openshift-storage -l app=rook-ceph-osd \
  -o custom-columns=MEM:.spec.containers[0].resources.requests.memory --no-headers \
  | sort | uniq -c

oc get pods -n openshift-storage -l app=rook-ceph-osd --field-selector=status.phase=Pending
```

If a pod stays at old limits after restart, check whether that **Deployment template** was
updated. Template still **2/5Gi** → Rook has not reconciled that deployment; restart the
operator or delete/recreate that one Deployment (one OSD at a time, never all at once).

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

### Default StorageClass for CNV

Use **`ocs-storagecluster-ceph-rbd-virtualization`** for VM disks (block mode, `mapOptions:
krbd:rxbounce`). ODF creates this StorageClass when OpenShift Virtualization is installed.

Kubernetes allows only **one** cluster default StorageClass. Unset the current default before
patching:

```bash
# List current cluster default(s)
oc get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}'

# Unset old default (commonly ocs-storagecluster-ceph-rbd)
oc patch storageclass ocs-storagecluster-ceph-rbd -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

# Set cluster default for virtualization RBD
oc patch storageclass ocs-storagecluster-ceph-rbd-virtualization -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

Verify:

```bash
oc get sc | grep default

oc get sc ocs-storagecluster-ceph-rbd-virtualization -o yaml | grep is-default
```

**CNV-only default:** OpenShift Virtualization also supports a separate virt-default annotation
(`storageclass.kubevirt.io/is-default-virt-class`). ODF often sets that on this StorageClass
automatically. Virt-default applies to VM/DataVolume workloads even when another StorageClass
is the cluster default. Use the cluster-default patch above when PVCs without
`storageClassName` (including boot sources) must land on the virtualization SC.

### ODF alerts

| Alert | Typical action |
|-------|----------------|
| `csi-addons-controller-manager` CrashLoop | Patch deployment memory (see above) |
| `ocs-metrics-exporter` OOMKilled | Patch deployment memory to 512M (see above) |
| `rook-ceph-operator` OOMKilled | Patch the CSV memory limit, not the Deployment (see above) |
| Ceph slow / `PausedIOError` on VMs | Check `ceph status`, OSD pods on affected node |
| PG backfill after `pg_num` change | Normal during rebalance; watch `ceph -s` until `active+clean` |

---

## Worker KubeletConfig

Worker nodes use a **KubeletConfig** CR so the Machine Config Operator (MCO) rolls kubelet
settings into the worker `MachineConfigPool`. Default OpenShift `maxPods` is typically **250**;
high-scale needs a much higher cap for dense VM/pod placement.

### highscale (`maxPods`)

Live CR (cluster-scoped, no namespace):

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: highscale
spec:
  kubeletConfig:
    maxPods: 1000
    nodeStatusMaxImages: -1
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/worker: ""
```

| Field | Value | Role |
|-------|-------|------|
| `maxPods` | `1000` | Upper bound on schedulable pods per worker node |
| `nodeStatusMaxImages` | `-1` | No cap on images reported in node status (avoids trimming image list on image-heavy nodes) |
| `machineConfigPoolSelector` | worker pool label | Applies only to workers, not masters |

`status.conditions` type **Success** = MCO generated and applied the worker MachineConfig.

Inspect:

```bash
oc get kubeletconfig highscale -o yaml
oc get mcp worker -o jsonpath='{.status.configuration.name}{"\n"}'
```

On a worker, confirm kubelet picked up the limit:

```bash
oc debug node/<worker> -- chroot /host grep maxPods /etc/kubernetes/kubelet.conf
```

**Note:** Raising `maxPods` requires sufficient pod network CIDR capacity, node CPU/memory, and
often companion tuning (`systemReserved`, descheduler/CNV migration limits). See templates under
`templates/kubelet/` for allocatable/reserved examples.

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
