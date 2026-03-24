# ocp-lab

A collection of learning materials, scripts, and templates for OCP. Includes hands-on guides for network tracing, eBPF, and OVN/OVS internals, along with reusable templates.

## Learning — table of contents

| Topic | Guide |
| ----- | ----- |
| eBPF | [eBPF lab](learning/ebpf/epbf-lab.md) |
| Ceph — storage | [PVC vs snapshot vs clone](learning/ceph/pvc-vs-snapshot-clone.md) |
| Monitoring | [Kernel `/proc/diskstats`](learning/monitoring/kernel-proc-diskstats.md) |
| Networking — tracing | [OpenShift network tracing](learning/networking/ocp-network-tracing/ocp-net-tracing.md) |
| Networking — single-node tracing | [Single-node OpenShift network tracing](learning/networking/single-node-ocp-network-tracking/single-node-ocp-net-tracing.md) |
| Networking — DNS | [DNS resolution debugging](learning/networking/dns-resolution-issue/dns-resolution-error.md) |

## Blogs — table of contents

| Topic | Article |
| ----- | ------- |
| Hosted control plane / KubeVirt | [Effortlessly and efficiently provision OpenShift clusters with OpenShift Virtualization](https://www.redhat.com/en/blog/effortlessly-and-efficiently-provision-openshift-clusters-with-openshift-virtualization) |
| Hosted control plane | [Correlating QPS rate with resource utilization in self-managed Red Hat OpenShift with Hosted Control Planes](https://www.redhat.com/en/blog/correlating-qps-rate-resource-utilization-self-managed-red-hat-openshift-hosted-control-planes) |
| OpenShift Virtualization — descheduler | [Dynamic VM CPU workload rebalancing with load-aware descheduler](https://developers.redhat.com/blog/2025/06/03/dynamic-vm-cpu-workload-rebalancing-load-aware-descheduler) |

## Structure

```
ocp-lab/
├── blogs/
├── learning/
│   ├── ceph/
│   ├── ebpf/
│   ├── monitoring/
│   └── networking/
│       ├── dns-resolution-issue/
│       ├── ocp-network-tracing/
│       └── single-node-ocp-network-tracking/
├── scripts/
│   ├── ceph/
│   ├── cnv/
│   ├── io/
│   ├── node/
│   ├── others/
│   └── promethus/
├── templates/
│   ├── cnv/
│   ├── dashboard/
│   ├── descheduler/
│   ├── haproxy/
│   ├── hpp/
│   ├── kubelet/
│   ├── kvm/
│   ├── lso/
│   ├── lvm/
│   ├── managedCluster/
│   ├── mce/
│   ├── metallb/
│   ├── multus/
│   ├── nginx/
│   ├── odf/
│   ├── promethus/
│   └── systemd/
```
