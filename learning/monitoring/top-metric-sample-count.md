# Top metric series count (Prometheus / OpenShift)

Lab notes for finding which metric names contribute the most **active time series** on an OpenShift cluster Prometheus, using the TSDB status API from a `prometheus-k8s` pod.

**Last Updated:** 2026-08-04

---

## What this measures

| Term | Meaning |
| ---- | ------- |
| **Time series** | One unique `__name__` + label set (e.g. one `container_network_receive_bytes_total` per pod/interface) |
| **Series count** | How many such series exist **right now** in this Prometheus pod’s **head** block |
| **Samples / scrape** | How many values a target returned in the last scrape (`scrape_samples_scraped`) — different metric |

The TSDB endpoint ranks metric **names** by **series count**. It is an instant view of current cardinality, **not** “all samples ever stored for the retention period.”

Official docs: [Prometheus HTTP API → TSDB Stats](https://prometheus.io/docs/prometheus/latest/querying/api/#tsdb-stats)

- Endpoint: `GET /api/v1/status/tsdb`
- Query param `limit`: number of entries returned per stats list (**default 10**, max 10000)
- Field `seriesCountByMetricName`: list of metric names and their series counts (highest first)

---

## Prerequisites

- `oc` access to the cluster
- Permission to `exec` into pods in `openshift-monitoring`
- `jq` on the machine where you run `oc` (for pretty output)

---

## 1. Query from the Prometheus pod

```bash
oc get pods -n openshift-monitoring -l app.kubernetes.io/name=prometheus

oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/status/tsdb?limit=20' \
| jq '.data.seriesCountByMetricName'
```

Notes:

- Use container `-c prometheus` (not the proxy sidecar).
- Either HA replica (`prometheus-k8s-0` or `-1`) is fine; each has its own local head and counts can differ slightly.
- Without `?limit=…`, Prometheus returns only **10** rows. `jq '.[ :20]'` cannot invent rows the API did not send.

### Total active series (all metrics)

`headStats.numSeries` is the **total number of active time series** in this Prometheus pod’s head (every metric name combined — not “samples over retention”).

```bash
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/status/tsdb' \
| jq '.data.headStats.numSeries'
```

Example from this cluster:

```text
14522167
```

Full head block stats (series + chunks + time range):

```bash
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/status/tsdb' \
| jq '.data.headStats'
```

| Want | Query / field |
| ---- | ------------- |
| Total **series** now | `headStats.numSeries` (above) — here **~14.5M** |
| Top series by **metric name** | `seriesCountByMetricName` (`?limit=20`) |
| Samples in **last scrape** | `sum(scrape_samples_scraped)` |
| Samples **appended** over time | `prometheus_tsdb_head_samples_appended_total` (counter) |

PromQL equivalent for total series (can be expensive at this scale; prefer TSDB API):

```promql
count({__name__=~".+"})
```

### Verify: do per-metric counts add up to `numSeries`?

List as many metric names as the API allows (`limit` max **10000**) and compare their sum to `headStats.numSeries`:

```bash
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/status/tsdb?limit=10000' \
| jq '{
    numSeries: .data.headStats.numSeries,
    listedMetrics: (.data.seriesCountByMetricName | length),
    sumOfListed: ([.data.seriesCountByMetricName[].value] | add),
    diff: (.data.headStats.numSeries - ([.data.seriesCountByMetricName[].value] | add))
  }'
```

| Field | Meaning |
| ----- | ------- |
| `numSeries` | Total active series in the head |
| `listedMetrics` | How many metric **names** the API returned |
| `sumOfListed` | Sum of series counts for those names |
| `diff` | `numSeries - sumOfListed` |

Interpretation:

- **`diff` ≈ 0** → listed per-metric counts account for the head total.
- **`listedMetrics` == 10000** and **`diff` still large** → more than 10k distinct metric names exist; the API truncated the list, so the sum cannot cover everything.
- Dump the full returned list (sorted):  

```bash
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/status/tsdb?limit=10000' \
| jq -r '.data.seriesCountByMetricName[] | "\(.value)\t\(.name)"' \
| sort -nr
```

---

## 2. Example result (large Virt / dense cluster)

Same cluster as above: **`headStats.numSeries` ≈ 14,522,167** (~14.5M active series). Top metric names below are the largest contributors; even #1 (`container_blkio_…` ≈ 421k) is only a few percent of the total.

Captured from cluster Prometheus (`limit=20`):

```json
[
  { "name": "container_blkio_device_usage_total", "value": 421054 },
  { "name": "container_network_transmit_packets_dropped_total", "value": 298110 },
  { "name": "container_network_transmit_bytes_total", "value": 298110 },
  { "name": "container_network_receive_packets_total", "value": 298110 },
  { "name": "container_network_receive_errors_total", "value": 298110 },
  { "name": "container_network_receive_packets_dropped_total", "value": 298110 },
  { "name": "container_network_receive_bytes_total", "value": 298110 },
  { "name": "container_network_transmit_errors_total", "value": 298110 },
  { "name": "container_network_transmit_packets_total", "value": 298110 },
  { "name": "node_cpu_seconds_total", "value": 225280 },
  { "name": "kubevirt_vmi_last_api_connection_timestamp_seconds", "value": 174791 },
  { "name": "kubevirt_portforward_active_tunnels", "value": 174778 },
  { "name": "container_fs_writes_total", "value": 143648 },
  { "name": "container_fs_reads_total", "value": 143648 },
  { "name": "container_fs_reads_bytes_total", "value": 142172 },
  { "name": "container_fs_writes_bytes_total", "value": 142172 },
  { "name": "kubevirt_rest_client_request_latency_seconds_bucket", "value": 111600 },
  { "name": "container_pressure_io_stalled_seconds_total", "value": 108282 },
  { "name": "container_memory_max_usage_bytes", "value": 108282 },
  { "name": "container_memory_total_inactive_file_bytes", "value": 108282 }
]
```

### How to read this

| Rank / family | Why cardinality is high |
| ------------- | ----------------------- |
| `container_blkio_device_usage_total` | kubelet/cAdvisor: per container × **device** × **operation** — often #1 on dense clusters |
| `container_network_*` (tied counts) | Same label shape: per pod/container × **interface** — eight metrics share ~the same series count |
| `node_cpu_seconds_total` | node-exporter: per node × **cpu** × **mode** |
| `kubevirt_vmi_last_api_connection_timestamp_seconds` | Gauge: last VMI API connection timestamp (VNC, console, portforward, SSH, usbredir). ~one series per VMI → high count at VM scale. [[metrics](https://kubevirt.io/monitoring/metrics.html)] [[PR #11934](https://github.com/kubevirt/kubevirt/pull/11934)] |
| `kubevirt_portforward_active_tunnels` | Gauge: active portforward tunnels, broken down by **namespace** and **vmi name**. [[metrics](https://kubevirt.io/monitoring/metrics.html)] |
| `kubevirt_rest_client_request_latency_seconds_bucket` | REST client latency histogram buckets (verb/URL dims) — buckets multiply series |
| `container_fs_*` / `container_memory_*` / pressure | More cAdvisor per-container series |

These top `container_*` / `node_*` metrics are **not Ceph metrics**. Ceph/ODF would appear as names like `ceph_*`, `rook_*`, `ocs_*`. Container blkio can *include* I/O that eventually hits Ceph-backed volumes, but the metric itself is still cAdvisor block I/O.

---

## 3. Filter families (KubeVirt / OVN / Ceph)

The TSDB list is global. To focus on one family, filter with `jq`:

```bash
# KubeVirt
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/status/tsdb?limit=200' \
| jq '[.data.seriesCountByMetricName[] | select(.name | startswith("kubevirt_"))] | .[:20]'

# OVN / OVS / ovnkube
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/status/tsdb?limit=500' \
| jq '[.data.seriesCountByMetricName[] | select(.name | test("^(ovn|ovs_|ovnkube_)"))] | .[:20]'

# Ceph / Rook / ODF-ish
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/status/tsdb?limit=500' \
| jq '[.data.seriesCountByMetricName[] | select(.name | test("ceph|rook|ocs|odf"; "i"))] | .[:20]'
```

Raise `limit` when filtering so high-cardinality names outside the global top-N still appear in the raw list before `jq` selects them.

---

## 4. PromQL alternative (same idea)

Instant query — currently active series, ranked by metric name:

```bash
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=topk(20, count by (__name__) ({__name__=~".+"}))' \
| jq '.data.result[] | {metric: .metric.__name__, series: .value[1]}'
```

Scoped examples:

```promql
topk(20, count by (__name__) ({__name__=~"kubevirt_.*"}))
topk(20, count by (__name__) ({__name__=~"ovn.*|ovs_.*|ovnkube_.*"}))
```

This can be expensive on a large TSDB; prefer `/api/v1/status/tsdb` when it works.

### Samples scraped (not series count)

```promql
topk(20, scrape_samples_scraped{namespace="openshift-ovn-kubernetes"})
sum by (job) (scrape_samples_scraped{job=~".*kubevirt.*"})
```

---

## 5. KubeVirt cardinality (context)

Rough model for VMI metrics (handlers partition VMs; do **not** multiply by node count):

```text
total VMI series ≈ (avg series per VMI) × (# VMIs)
```

A naive `~60 metric names × 8,000 VMs ≈ 480,000` is a **lower bound**. Extra labels (vCPU id/state, disk, NIC, histogram buckets) push real counts higher. On this cluster, global top cardinality is still dominated by **cAdvisor / node-exporter**, with some `kubevirt_*` names entering the top 20.

---

## 6. References

- [Prometheus HTTP API — TSDB Stats](https://prometheus.io/docs/prometheus/latest/querying/api/#tsdb-stats)
- [KubeVirt components metrics](https://kubevirt.io/monitoring/metrics.html) (`kubevirt_vmi_last_api_connection_timestamp_seconds`, `kubevirt_portforward_active_tunnels`, …)
- [kubevirt/kubevirt `docs/observability/metrics.md`](https://github.com/kubevirt/kubevirt/blob/main/docs/observability/metrics.md)
- [kubevirt/kubevirt#11934](https://github.com/kubevirt/kubevirt/pull/11934) — add last API connection timestamp metric
- [KubeVirt component monitoring](https://kubevirt.io/user-guide/user_workloads/component_monitoring/)
- OpenShift: Observe → Metrics (same PromQL against Thanos/Prometheus querier)
