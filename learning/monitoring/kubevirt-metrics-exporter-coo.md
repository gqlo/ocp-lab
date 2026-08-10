# KubeVirt Metrics Exporter + COO Perses

Lab notes for deploying [kubevirt-metrics-exporter](https://github.com/openshift-virtualization/kubevirt-metrics-exporter) on OpenShift and viewing its **KubeVirt Storage Latency** dashboard via Cluster Observability Operator (COO) Perses.

**Last Updated:** 2026-07-17

## What this stack is

| Piece | Role |
| ----- | ---- |
| **kubevirt-metrics-exporter** | DaemonSet that scrapes VM storage I/O latency (QMP, QGA, eBPF) and exposes Prometheus metrics |
| **PodMonitor + PrometheusRule** | Wired into cluster monitoring by the OpenShift install manifest |
| **PersesDashboard / PersesDatasource** | Dashboard-as-code CRs shipped with the exporter |
| **COO + Monitoring UIPlugin** | Installs Perses UI in the OpenShift console (`Observe → Dashboards (Perses)`) |

Upstream: [openshift-virtualization/kubevirt-metrics-exporter](https://github.com/openshift-virtualization/kubevirt-metrics-exporter)

---

## Prerequisites

- OpenShift 4.15+ (Perses via COO needs COO 1.5+ / feature available from COO 1.1+ on 4.15+)
- OpenShift Virtualization installed (VMIs to scrape)
- `cluster-admin` (or equivalent) to install operators, SCC, and UIPlugin
- Cluster monitoring able to scrape user workloads / PodMonitors in the exporter namespace

---

## 1. Install Cluster Observability Operator (COO)

### Console

1. **Operators → OperatorHub**
2. Search **Cluster Observability Operator**
3. Install (default namespace is typically `openshift-cluster-observability-operator`)

### CLI (OperatorHub Subscription)

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cluster-observability-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-cluster-observability-operator
  namespace: openshift-cluster-observability-operator
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: openshift-cluster-observability-operator
spec:
  channel: stable
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

Verify the operator is running:

```bash
oc get csv -n openshift-cluster-observability-operator
oc get pods -n openshift-cluster-observability-operator
oc get crd | grep -E 'uiplugins|perses'
```

COO installs Perses CRDs (`PersesDashboard`, `PersesDatasource`, `PersesGlobalDatasource`) and the Perses operator. The **console menu** for Perses still needs the Monitoring UIPlugin below.

---

## 2. Enable Perses via Monitoring UIPlugin

COO has several UIPlugin **types** (`Dashboards`, `Logging`, `DistributedTracing`, `TroubleshootingPanel`, `Monitoring`). Perses is **only** under `type: Monitoring`.

### Find existing UIPlugins

```bash
oc get uiplugins.observability.openshift.io -o custom-columns=\
NAME:.metadata.name,TYPE:.spec.type,PERSES:.spec.monitoring.perses.enabled
```

### Create or fix the Monitoring plugin

**Important:** `spec.type: Monitoring` alone is not enough. An empty `spec.monitoring` fails reconcile:

```text
monitoring configuration can not be empty for plugin type Monitoring
UIPluginFailedToReconcile / Degraded=True
```

Create (or replace) with Perses enabled:

```bash
oc apply -f - <<'EOF'
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: monitoring
spec:
  type: Monitoring
  monitoring:
    perses:
      enabled: true
EOF
```

If a Monitoring UIPlugin already exists, patch Perses on **that** object (do not create a second Monitoring plugin):

```bash
oc patch uiplugin monitoring --type=merge -p '{
  "spec": {
    "monitoring": {
      "perses": {
        "enabled": true
      }
    }
  }
}'
```

Optional features on the same plugin (only if you need them):

```yaml
spec:
  type: Monitoring
  monitoring:
    perses:
      enabled: true
    # incidents:
    #   enabled: true
    # acm:
    #   enabled: true
    #   alertmanager:
    #     url: 'https://alertmanager.open-cluster-management-observability.svc:9095'
    #   thanosQuerier:
    #     url: 'https://rbac-query-proxy.open-cluster-management-observability.svc:8443'
```

### Verify UIPlugin health

```bash
oc get uiplugin monitoring -o yaml
```

Expect `Reconciled=True`, `Available=True`, `Degraded=False`.

After a short wait, the console should show **Observe → Dashboards (Perses)**. Reload the browser if the menu is missing.

---

## 3. Install kubevirt-metrics-exporter

### From release (recommended)

```bash
oc apply -f https://github.com/openshift-virtualization/kubevirt-metrics-exporter/releases/latest/download/install-openshift.yaml
```

As of **v0.4.0**, the OpenShift manifest installs roughly:

| Kind | Name / notes |
| ---- | ------------ |
| Namespace | `kubevirt-metrics-exporter` |
| ServiceAccount + ClusterRole/Binding | Read pods, PVCs, VMIs |
| SecurityContextConstraints | hostPID, hostPath, BPF-related caps |
| DaemonSet | `quay.io/openshift-virtualization/kubevirt-metrics-exporter:v0.4.0` on workers |
| PodMonitor | Scrapes `:8080/metrics` every 30s |
| PrometheusRule | Storage latency + exporter health alerts |
| PersesDashboard | Display name **KubeVirt Storage Latency** |
| PersesDatasource | Thanos Querier (`thanos-querier.openshift-monitoring`) |

### Verify exporter

```bash
oc get ns kubevirt-metrics-exporter
oc get ds,pods,podmonitor,prometheusrule -n kubevirt-metrics-exporter
oc get persesdashboard,persesdatasource -n kubevirt-metrics-exporter
oc logs -n kubevirt-metrics-exporter -l app=kubevirt-metrics-exporter --tail=50
```

DaemonSet runs on workers with `hostPID`, mounts CRI socket + `/sys`, and enables QMP / QGA / eBPF by default (see env on the container).

### Metrics prefixes

- VMI storage: `kubevirt_vmi_storage_*`
- Exporter / eBPF ops: `kme_*`

Example — P99 write latency per VMI:

```promql
histogram_quantile(0.99,
  sum by (name, le) (
    rate(kubevirt_vmi_storage_io_latency_seconds_bucket{operation="write"}[5m])
  )
)
```

Confirm scrape in Prometheus (Observe → Metrics, or Thanos Querier):

```promql
up{job="kubevirt-metrics-exporter"}
```

---

## 4. Open the Perses dashboard

1. OpenShift console → **Observe → Dashboards (Perses)**
2. Project selector → **`kubevirt-metrics-exporter`**
3. Open **KubeVirt Storage Latency**

Dashboard panels cover kernel/device latency, NFS, Windows guest IOPS, QEMU→device, virtqueue utilization, with filters for node / namespace / VMI / volume.

### RBAC

Users need at least viewer roles on that namespace (cluster-admins usually already can):

- `persesdashboard-viewer-role`
- `persesdatasource-viewer-role`

Example RoleBinding for a user:

```bash
oc apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: user-perses-dashboard-viewer
  namespace: kubevirt-metrics-exporter
subjects:
  - kind: User
    name: <username>
    apiGroup: rbac.authorization.k8s.io
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: persesdashboard-viewer-role
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: user-perses-datasource-viewer
  namespace: kubevirt-metrics-exporter
subjects:
  - kind: User
    name: <username>
    apiGroup: rbac.authorization.k8s.io
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: persesdatasource-viewer-role
EOF
```

---

## Troubleshooting

| Symptom | Check |
| ------- | ----- |
| UIPlugin `Degraded`, empty monitoring config | Set `spec.monitoring.perses.enabled: true` (must not leave `monitoring:` empty) |
| No **Dashboards (Perses)** menu | COO installed? Monitoring UIPlugin Available? Hard-refresh console |
| Dashboard listed but no data | PodMonitor scraped? `up{job="kubevirt-metrics-exporter"}`; Thanos datasource / secrets; VMs running on workers |
| Empty exporter metrics | DaemonSet Ready on workers? Caps/SCC allowed? CRI socket path correct for the platform |
| Wrong UIPlugin patched | Use `spec.type: Monitoring` only — Logging/Dashboards/Tracing plugins do not enable Perses |

```bash
# UIPlugin status
oc get uiplugin monitoring -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'

# Exporter pods
oc get pods -n kubevirt-metrics-exporter -o wide

# Perses CRs from the install
oc get persesdashboard kubevirt-metrics-exporter -n kubevirt-metrics-exporter -o yaml | head -40
```

---

## Cleanup

```bash
oc delete -f https://github.com/openshift-virtualization/kubevirt-metrics-exporter/releases/latest/download/install-openshift.yaml

# Optional: remove Perses from Monitoring UIPlugin (or delete the UIPlugin)
oc patch uiplugin monitoring --type=merge -p '{"spec":{"monitoring":{"perses":{"enabled":false}}}}'
# oc delete uiplugin monitoring
```

Leaving COO installed is fine if other UI plugins / stacks still use it.

---

## References

- [kubevirt-metrics-exporter](https://github.com/openshift-virtualization/kubevirt-metrics-exporter)
- [Release install-openshift.yaml](https://github.com/openshift-virtualization/kubevirt-metrics-exporter/releases/latest/download/install-openshift.yaml)
- [COO UI plugins / Monitoring](https://github.com/rhobs/observability-operator/blob/main/docs/user-guides/observability-ui-plugins.md)
- [Perses dashboards (COO docs)](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/1-latest/html/ui_plugins_for_red_hat_openshift_cluster_observability_operator/perses-dashboard)
- Related lab note: [kernel-proc-diskstats.md](./kernel-proc-diskstats.md)
