# OCP Metrics Scrape Path

How metrics flow from a node exporter to Prometheus storage — verified on a live cluster node (`d36-h04-000-r660`, Intel Xeon Gold 5420+, 112 CPUs).

**Last Updated:** 2026-10-28

---

## Overview

OCP uses a **pull model**: Prometheus connects to exporters on demand. Metrics are
**not buffered on the node** — if the network is down, that scrape interval is lost
(though underlying kernel counters in `/proc` keep accumulating).

```
/proc, /sys, eBPF, QMP
        │
        ▼
  [ exporter process ]          (node_exporter, kubevirt-metrics-exporter, …)
  listens on 127.0.0.1:<port>   ← loopback only, not reachable externally
        │
        │  plain HTTP  (localhost)
        ▼
  [ kube-rbac-proxy ]           one per exporter
  listens on <node-IP>:9100     ← externally reachable, enforces TLS + RBAC token
        │
        │  HTTPS + Bearer token
        ▼
  [ prometheus-k8s-0 ]          \
  [ prometheus-k8s-1 ]          /  both HA replicas scrape independently
  openshift-monitoring namespace
        │
        │  stored in TSDB on PVC (4 TiB, 15d retention in this cluster)
        ▼
  [ thanos-querier ]            fan-out query layer across both replicas
        │
        ▼
  Grafana / OCP Console / PromQL clients
```

---

## Verified Connection State (live node)

```bash
# node_exporter ← kube-rbac-proxy (loopback)
ss -tnp | grep node_exporter
ESTAB  127.0.0.1:9101  ←→  127.0.0.1:36236   node_exporter pid=1493843 fd=6

# kube-rbac-proxy: both inbound (from prometheus) and outbound (to exporter)
ss -tnp | grep pid=1493864
ESTAB  10.1.62.12:9100  ←→  10.1.62.13:40107   (prometheus-k8s-0)
ESTAB  10.1.62.12:9100  ←→  10.1.62.8:38214    (prometheus-k8s-1)
ESTAB  127.0.0.1:36236  ←→  127.0.0.1:9101     (→ node_exporter)

# kube-rbac-proxy listen socket
ss -tlnp | grep pid=1493864
LISTEN  10.1.62.12:9100  0.0.0.0:*
```

Key observations:
- `node_exporter` binds **loopback only** (`127.0.0.1:9101`) — never directly reachable from the network.
- `kube-rbac-proxy` is the only process with an external listen socket (`<node-IP>:9100`).
- **Both** `prometheus-k8s-0` and `prometheus-k8s-1` maintain simultaneous connections to every node's `kube-rbac-proxy`. Each replica scrapes independently.

---

## Processes Involved (from `pstree`)

```
systemd
  ├── conmon───node_exporter       reads /proc, /sys → exposes node_* metrics
  ├── conmon───kube-rbac-proxy     auth proxy in front of node_exporter
  ├── conmon───exporter            kubevirt-metrics-exporter (QMP + eBPF)
  └── conmon───kube-rbac-proxy     auth proxy in front of kubevirt-metrics-exporter
```

Every exporter follows the same pattern: **exporter bound to loopback + kube-rbac-proxy
bound to node IP**.

---

## kube-rbac-proxy Role

| Responsibility | Detail |
|---|---|
| TLS termination | Prometheus connects over HTTPS; exporter speaks plain HTTP internally |
| Bearer token validation | Validates Prometheus's service account token against the k8s API (RBAC) |
| Network isolation | Exporter is invisible from outside the node without the proxy |

Without `kube-rbac-proxy`, any process that can reach the node's IP could scrape
metrics without authentication.

---

## Prometheus Storage

Configured via `cluster-monitoring-config` ConfigMap in `openshift-monitoring`:

```yaml
prometheusK8s:
  retention: 15d
  volumeClaimTemplate:
    spec:
      storageClassName: lvms-promethues-vg
      resources:
        requests:
          storage: 4096Gi
```

- Each `prometheus-k8s` replica writes to its **own PVC** (not shared).
- `thanos-querier` federates queries across both replicas so clients always get a
  complete view.

---

## What Happens if the Node Network Goes Down

| Layer | Outcome |
|---|---|
| Prometheus scrape | Fails — `up{job="node-exporter", instance="…"} = 0` recorded |
| Metric values | **Lost** for the outage window — no node-side buffering |
| Kernel counters (`/proc`) | **Keep accumulating** — unaffected by network |
| Counter metrics (`_total`) | Correct value when scraping resumes; `rate()` is inaccurate over the gap |
| Gauge / histogram metrics | Only current snapshot captured; intermediate values gone |
| Already-stored TSDB data | Safe — stored on PVC, independent of node connectivity |

---

## Scrape Interval and Ports

| Exporter | Listen address | Proxy port | Scrape interval |
|---|---|---|---|
| `node_exporter` | `127.0.0.1:9101` | `<node-IP>:9100` | 30s (default) |
| `kubevirt-metrics-exporter` | `127.0.0.1:8080` | `<node-IP>:<rbac-port>` | 30s (PodMonitor) |

Verify live:
```bash
# Confirm ports
ss -tlnp | grep kube-rbac-proxy

# Trigger a manual scrape to test connectivity
curl -sk -H "Authorization: Bearer $(oc whoami -t)" \
  https://<node-IP>:9100/metrics | head -20
```

---

## Related

- [top-metric-sample-count.md](top-metric-sample-count.md) — query Prometheus TSDB cardinality
- [kubevirt-metrics-exporter-coo.md](kubevirt-metrics-exporter-coo.md) — deploy kubevirt-metrics-exporter
- [install-openshift.yaml](install-openshift.yaml) — PodMonitor + ServiceMonitor manifests
- [OCP Monitoring docs](https://docs.openshift.com/container-platform/latest/observability/monitoring/monitoring-overview.html)
