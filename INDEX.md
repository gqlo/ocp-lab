# Index — find notes by symptom

Primary lookup for humans and AI. Prefer matching **symptoms** / error strings first, then open the linked note.

## Troubleshooting

| Symptoms / keywords | Domain | Note |
| ------------------- | ------ | ---- |
| OSD pods Running but `ceph osd` up count low; Rook 24h sleep; UDN / OVS overflow; OSDs flapping across zones | networking + storage | [udn-odf-osd-flapping](troubleshooting/networking/udn-odf-osd-flapping/udn-odf-osd-flapping.md) |
| DNS resolution failures on OpenShift | networking | [dns-resolution-error](troubleshooting/networking/dns-resolution-issue/dns-resolution-error.md) |
| `virtctl ssh` timeout; VMI status IP is `10.0.2.2` (masquerade guest IP) | virtualization | [kubevirt-vm-ssh-trace](troubleshooting/virtualization/kubevirt-vm-ssh-trace/kubevirt-vm-ssh-trace.md) |
| VM stuck at Starting; CPU starve / iDRAC | virtualization | [vm-stuck-at-starting](troubleshooting/virtualization/vm-stuck-at-starting/vm-stuck-at-starting.md) |
| MCP drain stuck; Rook/ODF PDBs vs `maxUnavailable`; OSD eviction blocks drain | storage | [odf-pdb-vs-mcp-drain](troubleshooting/storage/odf-pdb-vs-mcp-drain.md) |
| OSD FD count >1024; many `socket:` FDs; CRI-O `nofile=1024:2048`; OSD failures at ~200+ OSDs | storage | [osd-crio-nofile-fd-exhaustion](troubleshooting/storage/osd-crio-nofile-fd-exhaustion.md) |

## Runbooks

| Task | Domain | Note |
| ---- | ------ | ---- |
| Remove failed bare-metal workers (NotReady, no Machine API) | cluster-admin | [node-management](runbooks/cluster-admin/node-management.md) |
| Cluster upgrade notes | cluster-admin | [cluster-upgrade](runbooks/cluster-admin/cluster-upgrade.md) |
| Clean delete CNV/KubeVirt workloads at scale (VMs, PVCs, leftovers) | virtualization | [vm-workload-clean-deletion](runbooks/virtualization/vm-workload-clean-deletion.md) |

## Labs

| Topic | Domain | Note |
| ----- | ------ | ---- |
| OpenShift network tracing (OVN/OVS, nettools image) | networking | [ocp-net-tracing](labs/networking/ocp-network-tracing/ocp-net-tracing.md) |
| Single-node OCP network tracing | networking | [single-node-ocp-net-tracing](labs/networking/single-node-ocp-network-tracking/single-node-ocp-net-tracing.md) |
| eBPF / ocp-trace debugging | ebpf | [ebpf README](labs/ebpf/README.md) |
| PVC vs snapshot vs clone (Ceph) | storage | [pvc-vs-snapshot-clone](labs/storage/pvc-vs-snapshot-clone.md) |
| NetApp Trident NFS SVM setup | storage | [netapp-setup-notes](labs/storage/netapp/netapp-setup-notes.md) |
| Prometheus cardinality, KME/COO, diskstats, dirty rate | monitoring | [monitoring catalog](labs/monitoring/README.md) |
| High-scale cluster / ODF config notes | scale | [high-scale-config-notes](labs/scale/high-scale-config-notes.md) |
| Fedora CSB bootable USB | os-install | [fedora-csb-installation](labs/os-install/fedora-csb-installation.md) |

## Blogs

| Topic | Article |
| ----- | ------- |
| HCP + KubeVirt provider | [hosted-control-plane-with-the-kubevirt-provider](resources/blogs/hosted-control-plane-with-the-kubevirt-provider.md) |
| HCP resource usage / QPS | [hcp-resource-usage-pattern](resources/blogs/hcp-resource-usage-pattern.md) |
| Hypershift KubeVirt cluster config | [hypershift-kubevirt-cluster-config](resources/blogs/hypershift-kubevirt-cluster-config.md) |

## Resources

| Kind | Path |
| ---- | ---- |
| YAML templates | [resources/templates/](resources/templates/) (cnv, odf, multus, localnet, …) |
| Helper scripts | [resources/scripts/](resources/scripts/) (ceph, cnv, node, promethus, …) |
| Blogs | [resources/blogs/](resources/blogs/) |
