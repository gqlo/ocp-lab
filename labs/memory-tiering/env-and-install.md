# Memory tiering — env and install

**Last Updated:** 2026-10-13

Cluster / lab environment and install path for the memory-tiering feature stack
(swap, KSM zero pages, FPR, descheduler, autopilot).

## Catalog

- [Goal](#goal)
- [Cluster installation](#cluster-installation)
- [Worker SSH (bastion key)](#worker-ssh-bastion-key)
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

## Cluster installation

Bare-metal OpenShift for this lab is installed with **[Jetlag](https://github.com/redhat-performance/jetlag)** (Assisted Installer automation for Scale Lab / Performance Lab).

Local notes on Jetlag failures: [troubleshooting/jetlag/](../../troubleshooting/jetlag/).

## Worker SSH (bastion key)

After install, inject the **bastion** (`f24-h03-000-r670`) root SSH public key into the `core` user on all **workers** via MachineConfig so you can `ssh core@<worker>` from the bastion (e.g. for `free -h`, disk checks).

Get the key on the bastion:

```bash
cat ~/.ssh/id_rsa.pub
# or: cat /root/.ssh/id_rsa.pub
```

Apply (replace the key line if the bastion key rotates):

```bash
oc apply -f worker-ssh-key-mcp.yaml
oc get mcp worker   # wait until UPDATED=True
```

### `worker-ssh-key-mcp.yaml`

Paste the bastion public key into `sshAuthorizedKeys` (do not commit real keys to git). On vlan615 this was applied as `99-worker-ssh-key` from `root@f24-h03-000-r670`.

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-worker-ssh-key
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  config:
    ignition:
      version: 3.2.0
    passwd:
      users:
        - name: core
          sshAuthorizedKeys:
            - "<bastion-public-key>"
```

### Verify

```bash
oc get mc 99-worker-ssh-key
oc get mcp worker
ssh -o StrictHostKeyChecking=accept-new core@d37-h14-000-r660 free -h
```

Example (vlan615): MCP `worker` Updated=True, 9/9 ready after the MC rolled out.

## Environment

Captured from `oc` against `api.vlan615.rdu2.scalelab.redhat.com` (2026-10-13).

| Item | Value |
| ---- | ----- |
| Cluster / lab | Scale Lab RDU2 — **vlan615** (`vlan615.rdu2.scalelab.redhat.com`); API `https://api.vlan615.rdu2.scalelab.redhat.com:6443` |
| OpenShift | Server **4.22.17** (Available); client 4.22.9 |
| Kubernetes | v1.35.8 |
| Nodes | 3 masters + 9 workers (all Ready); MCP master/worker Updated |
| CNV / HCO | OpenShift Virtualization **4.22.12** (`kubevirt-hyperconverged-operator.v4.22.12`, Phase Succeeded); HCO `Available=True` |
| Nodes (CPU) | 112 CPUs/node (workers); 2× Intel Xeon Gold 5420+ (28 cores/socket, SMT), 2 NUMA nodes, VT-x |
| Nodes (disk) | On `d37-h14-000-r660`: OS `sda` 446G; 2× SCSI SSD **1.7T** (`sdb` LVMS, `sdc` unused); 1× NVMe **2.9T** (`nvme0n1`) |
| Nodes (RAM) | **~503Gi** / node (`free -h` on worker); swap **not enabled** (0B) before autopilot / swap-enable |
| Storage | LVMS **4.22.0** — SSD device class on `d37-h14-000-r660` (see below) |
| Autopilot | `virt-platform-autopilot` Deployment Ready; HCO annotation `platform.kubevirt.io/autopilot` **not set** yet |

## CNV installation

Install **OpenShift Virtualization** from Software Catalog in the OpenShift console (UI).
Create the `HyperConverged` instance with the console defaults (or equivalent) so CNV
operators and the HCO settle.

```bash
oc get csv -n openshift-cnv
oc get hyperconverged -n openshift-cnv
oc get pods -n openshift-cnv
```

Example output (vlan615, 2026-10-13):

```text
NAME                                        DISPLAY                    VERSION   RELEASE   REPLACES                                   PHASE
kubevirt-hyperconverged-operator.v4.22.12   OpenShift Virtualization   4.22.12             kubevirt-hyperconverged-operator.v4.22.9   Succeeded

NAME                      AGE
kubevirt-hyperconverged   22m
# Available=True (ReconcileCompleted); 61 pods Running in openshift-cnv
# including virt-handler on each node and virt-platform-autopilot
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
oc get csv -n openshift-lvm-storage
oc get lvmcluster -n openshift-lvm-storage
oc get storageclass | grep -E 'lvm|topolvm'
oc get pods -n openshift-lvm-storage
```

Example output (vlan615, 2026-10-13):

```text
NAME                    DISPLAY       VERSION   RELEASE   REPLACES                PHASE
lvms-operator.v4.22.0   LVM Storage   4.22.0              lvms-operator.v4.21.0   Succeeded

NAME             STATUS
ssd-lvmcluster   Ready

NAME                                    PROVISIONER   RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
lvms-lvm-d37-h14-000-r660-ssd-storage   topolvm.io    Delete          WaitForFirstConsumer   true                   35m

NAME                             READY   STATUS    RESTARTS      AGE
lvms-operator-84c9b89b5c-62x7r   1/1     Running   1 (44m ago)   45m
vg-manager-cp5gp                 1/1     Running   1 (35m ago)   35m
```

On the target node, confirm the by-path symlink and that LVMS claimed the disk
(no foreign filesystem / existing PV if the selector expects a raw device):

```bash
oc debug node/d37-h14-000-r660 -- chroot /host bash -c \
  'ls -l /dev/disk/by-path/pci-0000:4a:00.0-scsi-0:0:3:0; lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL; vgs'
```

Example output:

```text
lrwxrwxrwx. 1 root root 9 Oct 13 19:38 /dev/disk/by-path/pci-0000:4a:00.0-scsi-0:0:3:0 -> ../../sdb

NAME      SIZE TYPE FSTYPE      LABEL
sda     446.6G disk
|-sda1      1M part
|-sda2    127M part vfat        EFI-SYSTEM
|-sda3    384M part ext4        boot
`-sda4  446.1G part xfs         root
sdb       1.7T disk LVM2_member
sdc       1.7T disk
nvme0n1   2.9T disk

  VG                               #PV #LV #SN Attr   VSize  VFree
  lvm-d37-h14-000-r660-ssd-storage   1   0   0 wz--n- <1.75t <1.75t
```

`sdb` is `LVM2_member` under VG `lvm-d37-h14-000-r660-ssd-storage` (full free — no LVs yet). `sdc` / `nvme0n1` unused.

## Autopilot wiring

Overview and enablement (OpenShift Virtualization 4.22 developer preview):

- [Introducing virtualization platform autopilot](https://developers.redhat.com/articles/2026/05/07/introducing-virtualization-platform-autopilot) (Red Hat Developer, 2026-05-07)

Opt in on the HyperConverged CR (`platform.kubevirt.io/autopilot` annotation). Feature flags include `swap-enable`, `descheduler-loadaware`, `prometheus-alerts`, and others; use `true` for all. Dry-run via `virt-platform-autopilot` `/debug/render` is covered in the same article.

Baseline on vlan615 (before enable):

```bash
oc get deploy virt-platform-autopilot -n openshift-cnv
oc get hco kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.metadata.annotations}{"\n"}'
```

```text
NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
virt-platform-autopilot   1/1     1            1           23m

{"deployOVS":"false"}   # no platform.kubevirt.io/autopilot annotation yet
```

<!-- Fill in: lab-specific swap / KSM / FPR / descheduler choices after enable. -->

## Alerting dashboard (KContext)

Lab instance of [KContext](https://github.com/gqlo/KContext) — Alertmanager alerts ingested into Redis and browsable on an HTML dashboard (filters by severity, status, namespace, time range).

| | |
| --- | ----- |
| URL | [http://f24-h03-000-r670.rdu2.scalelab.redhat.com:8083/](http://f24-h03-000-r670.rdu2.scalelab.redhat.com:8083/) |
| Host | `f24-h03-000-r670` (Scale Lab bastion) |
| Listen | `:8083` (`LISTEN_ADDR`) |

Reachable from the lab network. Service install/ops: `KContext/utils/install-kcontext.sh` and [KContext docs](https://github.com/gqlo/KContext/blob/main/docs/dashboard.md).
