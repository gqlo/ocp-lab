# OCP Metrics Scrape Path

How metrics flow from a node exporter to Prometheus storage — verified on a live cluster node (`d36-h04-000-r660`, Intel Xeon Gold 5420+, 112 CPUs).

**Last Updated:** 2026-11-02

## Catalog

**Table of Contents**

- [OCP Metrics Scrape Path](#ocp-metrics-scrape-path)
  - [Catalog](#catalog)
  - [Overview](#overview)
  - [Exporter process: how `node_exporter` is started](#exporter-process-how-node_exporter-is-started)
  - [Walk a live node with `ss` (discovery)](#walk-a-live-node-with-ss-discovery)
    - [1. What is talking to `node_exporter`?](#1-what-is-talking-to-node_exporter)
    - [2. Which process owns the peer port?](#2-which-process-owns-the-peer-port)
    - [3. Who is listening, and on which addresses?](#3-who-is-listening-and-on-which-addresses)
    - [4. Who is connected to kube-rbac-proxy `:9100`?](#4-who-is-connected-to-kube-rbac-proxy-9100)
    - [5. Put it together](#5-put-it-together)
  - [Processes Involved (from `pstree`)](#processes-involved-from-pstree)
  - [kube-rbac-proxy Role](#kube-rbac-proxy-role)
    - [Verify auth vs open exporter](#verify-auth-vs-open-exporter)
  - [Prometheus Storage](#prometheus-storage)
  - [What Happens if the Node Network Goes Down](#what-happens-if-the-node-network-goes-down)
  - [Scrape Interval and Ports](#scrape-interval-and-ports)
  - [Related](#related)

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

## Exporter process: how `node_exporter` is started

Inspect the running process (PID from `ss` later, or from the DaemonSet pod):

```bash
ps -p 8302 -o args=
# or full argv:  tr '\0' ' ' < /proc/8302/cmdline; echo
```

Example (2026-11-02; line may truncate in the terminal — use `/proc/…/cmdline` for the rest):

```text
/bin/node_exporter \
  --web.listen-address=127.0.0.1:9101 \
  --path.sysfs=/host/sys \
  --path.rootfs=/host/root \
  --path.procfs=/host/root/proc \
  --path.udev.data=/host/root/run/udev/data \
  --no-collector.wifi \
  --collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run/k3s/containerd/.+|var/lib/docker/.+|var/lib/kubelet/pods/.+)($|/) \
  --collector.net…
```

| Flag | Meaning |
| ---- | ------- |
| `--web.listen-address=127.0.0.1:9101` | Metrics only on loopback (matches `ss` LISTEN) |
| `--path.sysfs=/host/sys` | Read host `/sys` via container mount |
| `--path.rootfs=/host/root` | Host root filesystem view |
| `--path.procfs=/host/root/proc` | Host `/proc` (CPU, memory, processes, …) |
| `--path.udev.data=…` | Host udev device metadata |
| `--no-collector.wifi` | Wi‑Fi collector disabled |
| `--collector.filesystem.mount-points-exclude=…` | Skip noisy/container mounts (`/dev`, `/proc`, `/sys`, docker/kubelet/k3s paths) |
| `--collector.net…` | Truncated in `ps`; usually netdev-related — confirm with `/proc/<pid>/cmdline` |

Default collectors (CPU, mem, disk, etc.) stay on unless disabled. The process runs in a
pod but scrapes the **node** through `/host/…` hostPath mounts, then serves Prometheus
text metrics on `127.0.0.1:9101` for kube-rbac-proxy to forward.

```text
Host /proc /sys /…  ──mounted──►  /host/… in container
                                      │
                                      ▼
                               node_exporter
                                      │
                                      ▼
                               127.0.0.1:9101/metrics
```

Also useful: `curl -sS http://127.0.0.1:9101/metrics | grep -E '^node_' | head` and
`oc -n openshift-monitoring get ds node-exporter -o yaml` for the DaemonSet args.

---

## Walk a live node with `ss` (discovery)

Start on a worker (e.g. `oc debug node/…` → `chroot /host`). Do **not** assume the architecture yet — follow the sockets. Ephemeral ports change; the pattern stays the same. Captured 2026-11-02.

### 1. What is talking to `node_exporter`?

```bash
ss -tnp | grep node_exporter
ESTAB 0  0  127.0.0.1:9101  127.0.0.1:33468  users:(("node_exporter",pid=8302,fd=7))
```

How to read one line (`ss -tnp`):

| Field | Example | Meaning |
| ----- | ------- | ------- |
| State | `ESTAB` | Active TCP connection |
| Local address | `127.0.0.1:9101` | **This** socket — owned by the process in `users:(…)` |
| Peer address | `127.0.0.1:33468` | The **other end** of the connection |
| `users:(…)` | `node_exporter` | Process that owns the **local** socket only — not the peer |

So: `node_exporter` is the **server** on port **9101**. Something on the same host connected from port **33468**.

Why both IPs are `127.0.0.1`: loopback — client and server are on **this** node. The IP names the host/interface; the **port** names the process. Same IP + different ports = two processes on one machine.

### 2. Which process owns the peer port?

`users:(…)` on the line above only names `node_exporter`. Grep the peer port to see the other side of the **same** TCP connection:

```bash
ss -tnp | grep 33468
ESTAB 0  0  127.0.0.1:9101   127.0.0.1:33468  users:(("node_exporter",pid=8302,fd=7))
ESTAB 0  0  127.0.0.1:33468  127.0.0.1:9101   users:(("kube-rbac-proxy",pid=8370,fd=9))
```

| Local | Peer | Process (`users`) |
| ----- | ---- | ----------------- |
| `127.0.0.1:9101` | `127.0.0.1:33468` | `node_exporter` (server) |
| `127.0.0.1:33468` | `127.0.0.1:9101` | **`kube-rbac-proxy`** (client) |

Conclusion so far: on this node, **kube-rbac-proxy** scrapes **node_exporter** over localhost (`:33468` → `:9101`).

### 3. Who is listening, and on which addresses?

```bash
ss -tlnp | grep -E '9100|9101'
LISTEN 0  4096  127.0.0.1:9101   0.0.0.0:*  users:(("node_exporter",pid=8302,fd=4))
LISTEN 0  4096  10.1.62.16:9100  0.0.0.0:*  users:(("kube-rbac-proxy",pid=8370,fd=7))
```

| Process | Listen address | Reachable from |
| ------- | -------------- | -------------- |
| `node_exporter` | `127.0.0.1:9101` | Only this host (loopback) |
| `kube-rbac-proxy` | `10.1.62.16:9100` (node Internal-IP) | Other nodes / cluster |

Prometheus cannot hit `:9101` from outside; it must hit **`:9100`** on the node IP.

### 4. Who is connected to kube-rbac-proxy `:9100`?

```bash
ss -tnp | grep 9100
ESTAB 0  0  10.1.62.16:9100  10.1.62.13:57215  users:(("kube-rbac-proxy",pid=8370,fd=8))
ESTAB 0  0  10.1.62.16:9100  10.1.62.8:37404   users:(("kube-rbac-proxy",pid=8370,fd=10))
```

| Field | Value | Meaning |
| ----- | ----- | ------- |
| Local | `10.1.62.16:9100` | This node’s kube-rbac-proxy (server) |
| Peer | `10.1.62.13:57215`, `10.1.62.8:37404` | Two remote clients (different hosts — not `127.0.0.1`) |

These peers are **not** the Prometheus **pod** IPs from `oc get pod -o wide`. Check what they are:

```bash
oc get pod -n openshift-monitoring -o wide | grep prometheus-k8s
# prometheus-k8s-0   10.128.2.3     d36-h07-000-r660
# prometheus-k8s-1   10.129.2.21    d35-h26-000-r660

oc get node d36-h07-000-r660 d35-h26-000-r660 -o wide
# d36-h07-000-r660   INTERNAL-IP   10.1.62.13
# d35-h26-000-r660   INTERNAL-IP   10.1.62.8
```

| Prometheus pod | Pod IP | Hosting node | Node Internal-IP (= `ss` peer) |
| -------------- | ------ | ------------ | ------------------------------ |
| `prometheus-k8s-0` | `10.128.2.3` | `d36-h07-000-r660` | **`10.1.62.13`** |
| `prometheus-k8s-1` | `10.129.2.21` | `d35-h26-000-r660` | **`10.1.62.8`** |

Pod IPs are on the OVN pod network (`10.128` / `10.129`). When a pod scrapes a **node IP** `:9100`, egress is often **SNATed** to the hosting node’s Internal-IP — so on the scraped node, `ss` shows `10.1.62.13` / `10.1.62.8`, not `10.128.2.3` / `10.129.2.21`.

Map an `ss` peer → Prometheus: peer IP → `oc get node -o wide` Internal-IP → node → which `prometheus-k8s-*` runs there. Both HA replicas scrape each node independently (two ESTAB lines).

### 5. Put it together

```text
prometheus-k8s-0/1  (pods on other nodes; ss peer = those nodes' Internal-IPs)
        │
        ▼  HTTPS to 10.1.62.16:9100
kube-rbac-proxy
        │
        ▼  HTTP  127.0.0.1:33468 → 127.0.0.1:9101
node_exporter
```

- Grep `node_exporter` → localhost hop only.
- Grep `9100` → remote Prometheus hop (peers look like node IPs).
- Grep the ephemeral peer port → prove the localhost client is `kube-rbac-proxy`.

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

Upstream project: [kube-rbac-proxy/kube-rbac-proxy](https://github.com/kube-rbac-proxy/kube-rbac-proxy) — Kubernetes RBAC–authorizing HTTP proxy for a single upstream.

| Responsibility | Detail |
|---|---|
| TLS termination | Prometheus connects over HTTPS; exporter speaks plain HTTP internally |
| Bearer token validation | Validates Prometheus's service account token against the k8s API (RBAC) |
| Network isolation | Exporter is invisible from outside the node without the proxy |

`node_exporter` itself has **no authentication** and listens only on loopback
(`127.0.0.1:9101`). `kube-rbac-proxy` on `<node-IP>:9100` is what enforces Bearer
token + RBAC for remote scrapes. If that same unauthenticated exporter were bound
to a reachable address with no proxy, anyone who can reach it could scrape metrics.

### Verify auth vs open exporter

Captured 2026-11-02 against node `10.1.62.16`. Cert-based logins (`system:admin`)
have no session token — `oc whoami -t` fails; mint an SA token instead:

```bash
TOKEN=$(oc -n openshift-monitoring create token prometheus-k8s --duration=1h)

# Proxy requires auth
curl -sk -o /dev/null -w 'no auth: %{http_code}\n' \
  https://10.1.62.16:9100/metrics
# no auth: 401

curl -sk -o /dev/null -w 'with auth: %{http_code}\n' \
  -H "Authorization: Bearer $TOKEN" \
  https://10.1.62.16:9100/metrics
# with auth: 200
```

On the node, the exporter answers with **no** token (plain HTTP):

```bash
curl -sS http://127.0.0.1:9101/metrics | head -5
# HELP go_gc_duration_seconds ...
# TYPE go_gc_duration_seconds summary
go_gc_duration_seconds{quantile="0"} ...
# curl: (23) Failure writing output to destination  ← harmless; head closed the pipe early
```

| Endpoint | Auth | Result |
| -------- | ---- | ------ |
| `https://<node-IP>:9100/metrics` | none | **401** |
| `https://<node-IP>:9100/metrics` | Bearer `prometheus-k8s` SA token | **200** |
| `http://127.0.0.1:9101/metrics` | none | metrics body (open) |

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

(Manual scrape / auth checks: see [Verify auth vs open exporter](#verify-auth-vs-open-exporter).)

---

## Related

- [kube-rbac-proxy](https://github.com/kube-rbac-proxy/kube-rbac-proxy) — upstream RBAC authorizing HTTP proxy
- [top-metric-sample-count.md](top-metric-sample-count.md) — query Prometheus TSDB cardinality
- [kubevirt-metrics-exporter-coo.md](kubevirt-metrics-exporter-coo.md) — deploy kubevirt-metrics-exporter
- [install-openshift.yaml](install-openshift.yaml) — PodMonitor + ServiceMonitor manifests
- [OCP Monitoring docs](https://docs.openshift.com/container-platform/latest/observability/monitoring/monitoring-overview.html)
