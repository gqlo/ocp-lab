# UDN workload impact on ODF: OSD flapping and Rook 24h sleep

**Last Updated:** 2026-08-25

Lab notes from a large ODF cluster (~219 OSDs, 1 OSD per worker node, replica 3 /
failure domain `zone`) after a User Defined Network (UDN) VM density workload
disrupted cluster networking.

## Catalog

- [Lesson (short)](#lesson-short)
- [Environment](#environment)
- [Symptoms](#symptoms)
- [Root cause chain](#root-cause-chain)
- [Example logs (osd.3)](#example-logs-osd3)
- [Recovery](#recovery)
- [Configuration reference](#configuration-reference)
- [Related](#related)
- [Refs](#refs)

---

## Lesson (short)

A UDN / KubeVirt VM deployment caused network issues on a large share of worker
nodes. Ceph OSDs lost heartbeats to peers and mons, flapped, and Ceph shut them
down. Rook then put **153 OSD pods to sleep for 24 hours** because the
`ceph-osd` daemon exited with code 0 (flapping protection).

After the UDN workload was deleted and **all nodes were Ready**, Ceph still did
not recover: `oc get pods` showed **219/219 OSD pods Running 2/2**, but only
**66 OSDs were up** in `ceph osd stat`. The pods looked healthy; the OSD daemons
were not running.

Fixing the network stopped new damage but did **not** restart sleeping OSD
daemons. Recovery required **manually deleting sleeping OSD pods in batches**
after confirming network was stable.

## Environment

| Item | Value |
|------|--------|
| Cluster | ~241 workers, 3 zones (`zone1`–`zone3`) |
| ODF | ~219 OSDs, 1 OSD per node |
| Pool | replica 3, failure domain `zone` |
| Trigger | UDN / VM density workload (network disruption) |
| CNI | OVN-Kubernetes |

Mons stayed healthy throughout (`quorum a,b,c`). This was not a mon/quorum
failure.

## Symptoms

Representative `ceph -s` during the incident:

```text
health: HEALTH_WARN
        98 osds down
        99 hosts (99 osds) down
        Reduced data availability: 5351 pgs inactive, 54 pgs down
        Degraded data redundancy: 239125/540984 objects degraded (44.202%)
        3 slow ops, oldest one blocked for ~74728 sec, osd.47 has slow ops

osd: 219 osds: 66 up (since ~75m), 164 in; 251 remapped pgs
```

Kubernetes layer during investigation:

```text
oc get nodes          → 244 Ready, 0 cordoned
oc get mcp worker     → UPDATED=True, UPDATING=False
oc get pods -l app=rook-ceph-osd → 219 Running, all 2/2 Ready
```

Down OSDs were spread across **all three zones** (~33 each), not a single-zone
outage. With replica 3 / failure domain `zone`, losing OSDs in every zone
simultaneously explains mass PG inactive/degraded state.

## Root cause chain

```text
UDN / VM workload disrupts OVN or host networking
        ↓
OSD heartbeat failures (peer + mon)
        ↓
OSDs marked down repeatedly by Ceph
        ↓
Ceph flapping threshold exceeded (>5 markdowns in 600s)
        ↓
ceph-osd exits cleanly (code 0) — "shutdown OSD via async signal"
        ↓
Rook OSD wrapper: exit 0 → sleep 24h (anti-flapping)
        ↓
Pod stays Running 2/2; Ceph shows OSD down; cluster does not self-heal
```

See [Example logs (osd.3)](#example-logs-osd3) for the full trace from this incident.

Ceph flapping defaults (unless overridden in `ceph config`):

| Setting | Default | Meaning |
|---------|---------|---------|
| [`osd_max_markdown_count`](https://github.com/ceph/ceph/blob/main/src/common/options/osd.yaml.in#L915-L919) | 5 | Max self-markdowns before Ceph stops the daemon |
| [`osd_max_markdown_period`](https://github.com/ceph/ceph/blob/main/src/common/options/osd.yaml.in#L910-L914) | 600 (`10_min`) | Rolling window in seconds |

When an OSD marks itself down **more than 5 times within 600 seconds**, Ceph shuts
it down on the next markdown (log: `marked down 6 > osd_max_markdown_count 5 in
last 600.000000 seconds, shutting down`). See [Example logs (osd.3)](#example-logs-osd3).

Verify on a running cluster:

```bash
ceph config show-with-defaults osd.3 | grep markdown
ceph config get osd osd_max_markdown_count
ceph config get osd osd_max_markdown_period
```

## Example logs (osd.3)

Pod: `rook-ceph-osd-3-774b48bdcc-w27g2` on node `e21-h33-000-r660` (zone1).

Fetch:

```bash
oc logs -n openshift-storage rook-ceph-osd-3-774b48bdcc-w27g2 -c osd --tail=30

# Key lines only
oc logs -n openshift-storage rook-ceph-osd-3-774b48bdcc-w27g2 -c osd 2>&1 \
  | grep -iE "heartbeat|shutdown OSD|Fast Shutdown|sleep for 24|sleep 24h|osd-sleep|ceph_osd_rc" \
  | tail -20
```

### 1. Heartbeat failures (network)

Repeated peer heartbeat timeouts immediately before shutdown. Earlier in the same
log stream, failures to other OSDs (e.g. osd.216 at `10.155.16.9:6804`) appear
as well.

```text
debug 2026-08-24T20:51:10.405+0000 7f9c5eb52640 -1 osd.3 139675 heartbeat_check: no reply from 10.132.0.8:6804 osd.2 since back 2026-08-24T20:50:44.215809+0000 front 2026-08-24T20:50:44.215871+0000 (oldest deadline 2026-08-24T20:51:07.715795+0000)
debug 2026-08-24T20:51:11.399+0000 7f9c5eb52640 -1 osd.3 139676 heartbeat_check: no reply from 10.132.0.8:6804 osd.2 since back 2026-08-24T20:50:44.215809+0000 front 2026-08-24T20:50:44.215871+0000 (oldest deadline 2026-08-24T20:51:07.715795+0000)
debug 2026-08-24T20:51:12.404+0000 7f9c5eb52640 -1 osd.3 139677 heartbeat_check: no reply from 10.132.0.8:6804 osd.2 since back 2026-08-24T20:50:44.215809+0000 front 2026-08-24T20:50:44.215871+0000 (oldest deadline 2026-08-24T20:51:07.715795+0000)
debug 2026-08-24T20:51:13.402+0000 7f9c5eb52640 -1 osd.3 139678 heartbeat_check: no reply from 10.132.0.8:6804 osd.2 since back 2026-08-24T20:50:44.215809+0000 front 2026-08-24T20:50:44.215871+0000 (oldest deadline 2026-08-24T20:51:07.715795+0000)
```

| Log fragment | Meaning |
|--------------|---------|
| `heartbeat_check: no reply from ... osd.N` | OSD cannot reach peer on cluster network (port 6804) |
| `since back ... front ...` | Front/back heartbeat channels both stale |
| `-1` level | Warning — connectivity problem, not yet fatal |

### 2. Ceph flapping shutdown (exit code 0)

After repeated markdowns, Ceph stops the daemon cleanly:

```text
debug 2026-08-24T20:51:24.895+0000 7f9c550d0640  0 osd.3 139689 _committed_osd_maps shutdown OSD via async signal
debug 2026-08-24T20:51:24.895+0000 7f9c66daf640  0 osd.3 139689 Fast Shutdown: - cct->_conf->osd_fast_shutdown = 1, null-fm = 1
debug 2026-08-24T20:51:25.124+0000 7f9c66daf640  0 osd.3 139689 Fast Shutdown duration total     :0.228950 seconds
debug 2026-08-24T20:51:25.124+0000 7f9c66daf640  0 osd.3 139689 Fast Shutdown duration osd_drain :0.001853 seconds
debug 2026-08-24T20:51:25.124+0000 7f9c66daf640  0 osd.3 139689 Fast Shutdown duration umount    :0.226745 seconds
debug 2026-08-24T20:51:25.124+0000 7f9c66daf640  0 osd.3 139689 Fast Shutdown duration timer     :0.000117 seconds
```

| Log fragment | Meaning |
|--------------|---------|
| `shutdown OSD via async signal` | Ceph initiated shutdown (flapping threshold or map commit) |
| `Fast Shutdown` | `osd_fast_shutdown=true` — immediate teardown |
| `bluefs umount` / `bdev ... close` | Normal daemon exit, not a crash |

### 3. Rook wrapper → 24h sleep

The `+` lines in pod logs are **bash trace output** (`bash -x`) from Rook’s OSD
wrapper — not Ceph debug. The wrapper runs `ceph-osd` in the background; if it
exits with code **0** (and SIGTERM was not received), the wrapper sleeps instead
of letting Kubernetes restart the daemon immediately.

**Source (Rook git):** [`pkg/operator/ceph/cluster/osd/cephosd-start.sh`](https://github.com/rook/rook/blob/master/pkg/operator/ceph/cluster/osd/cephosd-start.sh)  
Embedded at operator build time in [`spec.go`](https://github.com/rook/rook/blob/master/pkg/operator/ceph/cluster/osd/spec.go) (`//go:embed cephosd-start.sh`).

**On ODF:** there is no script file inside the pod. Rook injects the script into
each OSD Deployment’s `command` field. Sleep duration comes from env
`ROOK_OSD_RESTART_INTERVAL`, set from
`CephCluster.spec.storage.flappingRestartIntervalHours` (24 on this cluster).

View on a running OSD deployment:

```bash
oc get deploy rook-ceph-osd-3 -n openshift-storage \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="osd")].command}{"\n"}'

oc get deploy rook-ceph-osd-3 -n openshift-storage \
  -o jsonpath='{range .spec.template.spec.containers[?(@.name=="osd")].env[*]}{.name}={.value}{"\n"}{end}' \
  | grep ROOK_OSD_RESTART_INTERVAL
```

From `oc describe pod` / Deployment spec — wrapper script plus `ceph-osd` args
(`--` separates wrapper from the daemon command):

```text
Command:
  bash
  -x
  -c

  set -o nounset # fail if variables are unset
  child_pid=""
  sigterm_received=false
  function sigterm() {
    echo "SIGTERM received"
    sigterm_received=true
    kill -TERM "$child_pid"
  }
  trap sigterm SIGTERM
  "${@}" &
  child_pid="$!"
  wait "$child_pid"
  wait "$child_pid"
  ceph_osd_rc=$?
  if [ $ceph_osd_rc -eq 0 ] && ! $sigterm_received; then
    touch /tmp/osd-sleep
    echo "OSD daemon exited with code 0, possibly due to OSD flapping. The OSD pod will sleep for $ROOK_OSD_RESTART_INTERVAL hours. Restart the pod manually once the flapping issue is fixed"
    sleep "$ROOK_OSD_RESTART_INTERVAL"h &
    child_pid="$!"
    wait "$child_pid"
    wait "$child_pid"
  fi
  exit $ceph_osd_rc

  --
  ceph-osd
```

**Example log output** when the wrapper enters sleep (osd.3, 2026-08-24):

```text
+ wait 405
+ ceph_osd_rc=0
+ '[' 0 -eq 0 ']'
+ false
+ touch /tmp/osd-sleep
+ echo 'OSD daemon exited with code 0, possibly due to OSD flapping. The OSD pod will sleep for 24 hours. Restart the pod manually once the flapping issue is fixed'
OSD daemon exited with code 0, possibly due to OSD flapping. The OSD pod will sleep for 24 hours. Restart the pod manually once the flapping issue is fixed
+ child_pid=4557
+ wait 4557
+ sleep 24h
```

| Log fragment | Meaning |
|--------------|---------|
| `ceph_osd_rc=0` | Wrapper saw clean exit → assumes flapping |
| `touch /tmp/osd-sleep` | Suppresses liveness probe restarts |
| `sleep for 24 hours` | Human-readable message (matches `flappingRestartIntervalHours`) |
| `+ sleep 24h` | Container stays alive; **no** `ceph-osd` process after this line |
| Pod `Running 2/2` | Misleading — sidecar + sleep, not an active OSD |

After this point the log stream **stops producing Ceph debug lines**. `oc get
pods` still shows Ready because the wrapper process is sleeping.

### 4. Contrast: healthy OSD still running

osd.111 (up during the same incident) continues emitting normal Ceph debug:

```text
debug 2026-08-25T18:09:38.675+0000 7fb904ef0640  0 log_channel(cluster) log [DBG] : 2.122 scrub ok
```

Sleeping pod tail (osd.10):

```text
+ sleep 24h
```

Quick check:

```bash
# Sleeping
oc logs -n openshift-storage <osd-pod> -c osd --tail=3 | grep -E "sleep 24h|sleep for 24"

# Healthy — recent ceph debug, no sleep line
oc logs -n openshift-storage <osd-pod> -c osd --tail=3 | grep "debug 20"
```

## Recovery

**Prerequisites:** network stable, UDN workload removed, nodes Ready.

**Do not** restart all 219 OSD pods at once on this fleet. Use batches and watch
`ceph -s` between batches (see
[high-scale ODF notes](../../ocp-admin/high-scale-config-notes.md)).

### Restart one sleeping OSD (smoke test)

Run from your workstation (`oc` only):

```bash
oc delete pod -n openshift-storage -l ceph-osd-id=3
```

Watch from **rook-ceph-tools** (see
[`scripts/ceph/ceph-terminal.sh`](../../../scripts/ceph/ceph-terminal.sh)):

```bash
~/work/ocp-lab/scripts/ceph/ceph-terminal.sh watch -n5 'ceph osd stat; ceph pg stat'
```

### Batched restart of sleeping pods only

Run from your workstation. Uses **`oc` only** — no local `ceph` binary needed.
Iterates all OSD pods and restarts those whose logs end with `sleep 24h`; skips
pods with a running `ceph-osd` daemon.

```bash
BATCH=10
PAUSE=30
n=0

for pod in $(oc get pods -n openshift-storage -l app=rook-ceph-osd \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  id=$(oc get pod -n openshift-storage "$pod" \
    -o jsonpath='{.metadata.labels.ceph-osd-id}')
  if ! oc logs -n openshift-storage "$pod" -c osd --tail=5 2>/dev/null | grep -q "sleep 24h"; then
    echo "osd.$id: daemon running or unknown state — skip"
    continue
  fi
  echo "Restarting sleeping osd.$id ($pod)"
  oc delete pod -n openshift-storage "$pod" --wait=false
  ((++n))
  if (( n % BATCH == 0 )); then
    echo "Batch of $BATCH done — check ceph -s"
    sleep "$PAUSE"
  fi
done
```

Between batches, check progress from the toolbox:

```bash
~/work/ocp-lab/scripts/ceph/ceph-terminal.sh ceph -s
```

Tune `BATCH` and `PAUSE` from recovery pressure on the surviving OSDs.

## Configuration reference

Check Rook flapping sleep interval on the cluster:

```bash
oc get cephcluster -n openshift-storage \
  -o jsonpath='flappingRestartIntervalHours={.items[0].spec.storage.flappingRestartIntervalHours}{"\n"}'
# flappingRestartIntervalHours=24
```

On this ODF cluster the field is under **`spec.storage`**, not top-level
`spec.flappingRestartIntervalHours` (that jsonpath returns empty). ODF sets it
explicitly to **24** on `ocs-storagecluster-cephcluster`.

| `flappingRestartIntervalHours` | Behavior |
|--------------------------------|----------|
| `24` (default) | Sleep 24h after flapping exit; manual pod delete to recover sooner |
| `0` | Disable sleep; OSD wrapper retries immediately (less safe during flapping) |

CephCluster field documented in
[Rook CephCluster CRD — flappingRestartIntervalHours](https://rook.io/docs/rook/latest/CRDs/Cluster/ceph-cluster-crd/).

False positives: exit code 0 can also occur on OOM/SIGTERM edge cases
([Rook #12972](https://github.com/rook/rook/issues/12972)); treat logs, not just
the sleep message, as ground truth.

## Related

- [ODF / Rook PDBs vs MCP drain](../../ceph/odf-pdb-vs-mcp-drain.md) — different failure mode (drain/PDB), same fleet
- [High-scale ODF / batched OSD restart](../../ocp-admin/high-scale-config-notes.md)
- [OCP network tracing](../ocp-network-tracing/ocp-net-tracing.md)

## Refs

Ceph flapping (`osd_max_markdown_count` / `osd_max_markdown_period`):

- [Ceph `osd.yaml.in` defaults](https://github.com/ceph/ceph/blob/main/src/common/options/osd.yaml.in) — authoritative source for both options
- [Ceph PR #6708](https://github.com/ceph/ceph/pull/6708) — *osd: shut down if we flap too many times in a short period*
- [Ceph QA `osd-markdown.sh`](https://github.com/ceph/ceph/blob/main/qa/standalone/osd/osd-markdown.sh) — standalone tests for markdown count/period
- [Rook issue #12682](https://github.com/rook/rook/issues/12682) — Ceph flapping vs Kubernetes OSD pod restart policy

Rook OSD sleep / ODF:

- [Rook CephCluster CRD — `flappingRestartIntervalHours`](https://rook.io/docs/rook/latest/CRDs/Cluster/ceph-cluster-crd/)
- [Rook PR #12715](https://github.com/rook/rook/pull/12715) — OSD pod sleep on flapping
- [Rook issue #12972](https://github.com/rook/rook/issues/12972) — false-positive sleep on OOM/SIGTERM

Other:

- [Kubernetes Pod disruption budgets](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/)
