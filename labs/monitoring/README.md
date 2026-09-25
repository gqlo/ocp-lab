# Monitoring on OpenShift

Lab notes for **Prometheus cardinality**, **KubeVirt metrics**, **VM dirty rate (QEMU monitor)**, **storage I/O stats**, and related OpenShift Observability tooling.

**Last Updated:** 2026-08-10

## Catalog

| Doc | Topic |
| --- | ----- |
| [top-metric-sample-count.md](top-metric-sample-count.md) | Query Prometheus TSDB from `prometheus-k8s`: total head series, top metric names by series count, verify sums, filter KubeVirt / OVN / Ceph |
| [kubevirt-metrics-exporter-coo.md](kubevirt-metrics-exporter-coo.md) | Deploy kubevirt-metrics-exporter + COO Perses storage-latency dashboard |
| [qemu-monitor-dirty-rate-calculation.md](qemu-monitor-dirty-rate-calculation.md) | How QEMU `calc-dirty-rate` / `query-dirty-rate` work via `virsh qemu-monitor-command` (libvirt passthrough → KVM dirty bitmap) |
| [kernel-proc-diskstats.md](kernel-proc-diskstats.md) | How `/proc/diskstats` counts reads/writes (basis for many disk metrics) |
| [install-openshift.yaml](install-openshift.yaml) | Manifest used with monitoring / exporter install experiments |
| [`../../resources/templates/dashboard/json/descheduler_cnv.json`](../../resources/templates/dashboard/json/descheduler_cnv.json) | Grafana dashboard: descheduler + CNV (ideal-point distance, network utilization, migrations). Provision with vstorm [`provision-grafana-dashboards.sh`](../../../vstorm/monitoring/scripts/provision-grafana-dashboards.sh) |

## Related

- [eBPF / ocp-trace](../ebpf/README.md)
- [Network tracing](../networking/ocp-network-tracing/)
- [KubeVirt VM SSH path](../../troubleshooting/virtualization/kubevirt-vm-ssh-trace/kubevirt-vm-ssh-trace.md)
- [KubeVirt metrics catalog](https://kubevirt.io/monitoring/metrics.html)
