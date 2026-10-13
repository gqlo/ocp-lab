# Memory tiering — env and install

**Last Updated:** 2026-10-13

Cluster / lab environment and install path for the memory-tiering feature stack
(swap, KSM zero pages, FPR, descheduler, autopilot).

## Catalog

- [Goal](#goal)
- [Environment](#environment)
- [CNV installation](#cnv-installation)
- [LVMCluster (LVMS / SSD)](#lvmcluster-lvms--ssd)
  - [LVMCluster CR](#lvmcluster-cr)
  - [Verify](#verify)
- [Autopilot wiring](#autopilot-wiring)
- [Alerting dashboard (KContext)](#alerting-dashboard-kcontext)

---

## Goal

Document a reproducible lab: which cluster, OpenShift / CNV versions, hardware, and how
the memory-tiering stack is brought up (including autopilot).

## Environment

<!-- Fill in: cloud / Scale Lab site, node roles, OCP + CNV versions, storage, network. -->

| Item | Value |
| ---- | ----- |
| Cluster / lab | TBD |
| OpenShift (client / server) | 4.22.17 |
| Kubernetes | v1.35.8 |
| CNV / HCO | OpenShift Virtualization **4.22.12** (`kubevirt-hyperconverged-operator.v4.22.12`, Phase Succeeded) |
| Nodes (CPU) | 2× Intel Xeon Gold 5420+ (28 cores/socket, SMT), 112 CPUs, 2 NUMA nodes, VT-x |
| Nodes (disk) | 2× SCSI SSD **1.7T** (`sdb`, `sdc`); 1× NVMe **2.9T** (`nvme0n1`) |
| Nodes (RAM) | TBD |
| Storage | LVMS — SSD device class on `d37-h14-000-r660` (see below) |

## CNV installation

Install **OpenShift Virtualization** from Software Catalog in the OpenShift console (UI).
Create the `HyperConverged` instance with the console defaults (or equivalent) so CNV
operators and the HCO settle.

```bash
oc get csv -n openshift-cnv
oc get hyperconverged -n openshift-cnv
oc get pods -n openshift-cnv
```

## LVMCluster (LVMS / SSD)

Install the LVM Storage operator from Software Catalog in the OpenShift console (UI), then apply the `LVMCluster` CR below.
LVMS `LVMCluster` binding a single SCSI SSD path to hostname `d37-h14-000-r660`.
Device class name encodes the node + `ssd-storage` so StorageClasses / PVCs can select it
explicitly.

Captured from bastion/workdir `f24-h03-000-r670` (`lvm/lvmcluster.yaml`).

| Field | Value |
| ----- | ----- |
| Namespace | `openshift-lvm-storage` |
| CR name | `ssd-lvmcluster` |
| Device class | `lvm-d37-h14-000-r660-ssd-storage` |
| Device path | `/dev/disk/by-path/pci-0000:4a:00.0-scsi-0:0:3:0` |
| Node | `d37-h14-000-r660` (`kubernetes.io/hostname`) |

Prefer stable `/dev/disk/by-path/...` over `/dev/sdX` so the VG survives reboots /
re-enumeration.

### LVMCluster CR

```yaml
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: ssd-lvmcluster
  namespace: openshift-lvm-storage
spec:
  storage:
    deviceClasses:
    - name: lvm-d37-h14-000-r660-ssd-storage
      deviceSelector:
        paths:
          - /dev/disk/by-path/pci-0000:4a:00.0-scsi-0:0:3:0
      nodeSelector:
        nodeSelectorTerms:
        - matchExpressions:
          - key: kubernetes.io/hostname
            operator: In
            values:
            - d37-h14-000-r660
```

Apply (from the lab `lvm/` directory or after saving the manifest):

```bash
oc apply -f lvmcluster.yaml
```

Generic / multi-node examples also live under
[`resources/templates/lvm/lvmcluster.yaml`](../../resources/templates/lvm/lvmcluster.yaml)
and [`multi-pool.yaml`](../../resources/templates/lvm/multi-pool.yaml).

### Verify

```bash
oc get lvmcluster -n openshift-lvm-storage
oc get storageclass | grep -E 'lvm|topolvm'
oc get pods -n openshift-lvm-storage
```

On the target node, confirm the by-path symlink and that LVMS claimed the disk
(no foreign filesystem / existing PV if the selector expects a raw device):

```bash
ls -l /dev/disk/by-path/pci-0000:4a:00.0-scsi-0:0:3:0
lsblk -f
```

## Autopilot wiring

Overview and enablement (OpenShift Virtualization 4.22 developer preview):

- [Introducing virtualization platform autopilot](https://developers.redhat.com/articles/2026/05/07/introducing-virtualization-platform-autopilot) (Red Hat Developer, 2026-05-07)

Opt in on the HyperConverged CR (`platform.kubevirt.io/autopilot` annotation). Feature flags include `swap-enable`, `descheduler-loadaware`, `prometheus-alerts`, and others; use `true` for all. Dry-run via `virt-platform-autopilot` `/debug/render` is covered in the same article.

<!-- Fill in: lab-specific swap / KSM / FPR / descheduler choices and verify commands. -->

## Alerting dashboard (KContext)

Lab instance of [KContext](https://github.com/gqlo/KContext) — Alertmanager alerts ingested into Redis and browsable on an HTML dashboard (filters by severity, status, namespace, time range).

| | |
| --- | ----- |
| URL | [http://f24-h03-000-r670.rdu2.scalelab.redhat.com:8083/](http://f24-h03-000-r670.rdu2.scalelab.redhat.com:8083/) |
| Host | `f24-h03-000-r670` (Scale Lab bastion) |
| Listen | `:8083` (`LISTEN_ADDR`) |

Reachable from the lab network. Service install/ops: `KContext/utils/install-kcontext.sh` and [KContext docs](https://github.com/gqlo/KContext/blob/main/docs/dashboard.md).
