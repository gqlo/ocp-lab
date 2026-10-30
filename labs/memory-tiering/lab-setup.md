# Memory tiering — lab setup

**Last Updated:** 2026-10-26

Cluster / lab environment and install path for the memory-tiering feature stack
(swap, KSM zero pages, FPR, descheduler, autopilot).

## Catalog

<!-- If you don't use emacs, you can edit this manually -->
<!-- markdown-toc start - Don't edit this section. Run M-x markdown-toc-refresh-toc -->
**Table of Contents**

- [Memory tiering — lab setup](#memory-tiering--lab-setup)
  - [Catalog](#catalog)
  - [Goal](#goal)
  - [Cluster installation](#cluster-installation)
  - [Environment](#environment)
    - [Worker SSH (bastion key)](#worker-ssh-bastion-key)
    - [CNV installation](#cnv-installation)
    - [LVMCluster (LVMS / SSD)](#lvmcluster-lvms--ssd)
    - [Cluster upgrade to 5.0](#cluster-upgrade-to-50)
  - [Autopilot](#autopilot)
    - [List features on the cluster](#list-features-on-the-cluster)
  - [SWAP](#swap)
    - [Create partition](#create-partition)
    - [Enable via Autopilot](#enable-via-autopilot)
    - [Verify swap is enabled](#verify-swap-is-enabled)
  - [FPR (free page reporting)](#fpr-free-page-reporting)
    - [Verify from HCO operator config](#verify-from-hco-operator-config)
    - [Verify from the guest](#verify-from-the-guest)
  - [KSM (kernel samepage merging)](#ksm-kernel-samepage-merging)
    - [Before enable (baseline)](#before-enable-baseline)
    - [Enable via Autopilot](#enable-via-autopilot-1)
    - [After enable](#after-enable)
  - [THP (transparent huge pages)](#thp-transparent-huge-pages)
    - [Before enable (baseline)](#before-enable-baseline-1)
    - [Enable via Autopilot](#enable-via-autopilot-3)
  - [Descheduler (load-aware)](#descheduler-load-aware)
    - [Enable via autopilot](#enable-via-autopilot-2)
    - [KubeDescheduler instance](#kubedescheduler-instance)
    - [PSI kernel argument](#psi-kernel-argument)
    - [Policy / Prometheus metrics](#policy--prometheus-metrics)
    - [Verify](#verify)
  - [Alerting dashboard (KContext)](#alerting-dashboard-kcontext)

<!-- markdown-toc end -->

---

## Goal

Document a reproducible lab: which cluster, OpenShift / CNV versions, hardware, and how
the memory-tiering stack is brought up (including autopilot).

## Cluster installation

Bare-metal OpenShift for this lab is installed with **[Jetlag](https://github.com/redhat-performance/jetlag)** (Assisted Installer automation for Scale Lab / Performance Lab).

Local notes on Jetlag failures: [troubleshooting/jetlag/](../../troubleshooting/jetlag/).

## Environment

Last updated 2026-10-30 (upgraded to OCP 5.0). Initial capture 2026-10-13 (4.22.17).

| Item | Value |
| ---- | ----- |
| Cluster / lab | Scale Lab RDU2 — **vlan615** (`vlan615.rdu2.scalelab.redhat.com`); API `https://api.vlan615.rdu2.scalelab.redhat.com:6443` |
| OpenShift | Server **5.0.0** (Available); ~~4.22.17~~ |
| Kubernetes | v1.36.5 ~~(v1.35.8)~~ |
| Nodes | 3 masters + 9 workers (all Ready); MCP master/worker Updated |
| CNV / HCO | OpenShift Virtualization **4.22.12** (`kubevirt-hyperconverged-operator.v4.22.12`, Phase Succeeded); HCO `Available=True` |
| Nodes (CPU) | 112 CPUs/node (workers); 2× Intel Xeon Gold 5420+ (28 cores/socket, SMT), 2 NUMA nodes, VT-x |
| Nodes (disk) | On `d37-h14-000-r660`: OS `sda` 446G; 2× SCSI SSD **1.7T** (`sdb` LVMS, `sdc` unused); 1× NVMe **2.9T** (`nvme0n1`) |
| Nodes (RAM) | **~503Gi** / node (`free -h` on worker); swap **not enabled** (0B) before autopilot / swap-enable |
| Storage | LVMS **4.22.0** — SSD device class on `d37-h14-000-r660` (see below) |
| Autopilot | `virt-platform-autopilot` Ready; HCO annotation `platform.kubevirt.io/autopilot=descheduler-loadaware` (2026-10-19) |
| Descheduler | Operator **5.4.3**; `KubeDescheduler/cluster` Managed, profile `KubeVirtRelieveAndMigrate`, mode Automatic; workers have `psi=1` |

### Worker SSH (bastion key)

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

`worker-ssh-key-mcp.yaml` — paste the bastion public key into `sshAuthorizedKeys`
(do not commit real keys to git). On vlan615 this was applied as
`99-worker-ssh-key` from `root@f24-h03-000-r670`.

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

Verify:

```bash
oc get mc 99-worker-ssh-key
oc get mcp worker
ssh -o StrictHostKeyChecking=accept-new core@d37-h14-000-r660 free -h
```

Example (vlan615): MCP `worker` Updated=True, 9/9 ready after the MC rolled out.

### CNV installation

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

### LVMCluster (LVMS / SSD)

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

LVMCluster CR:

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

Verify:

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

### Cluster upgrade to 5.0

Upgrade blocked by `ClusterVersionUpgradeable` / `ClusterVersionOverridesSet`. Root
cause: `spec.overrides` on `ClusterVersion/version` marks `ClusterImagePolicy/openshift`
as `unmanaged: true`, so CVO can no longer reconcile it — it won't proceed with an
upgrade it can't guarantee is safe \[[12](#ref-12)\].

```bash
# inspect
oc get clusterversion version -o jsonpath='{.spec.overrides}{"\n"}'
# [{"group":"config.openshift.io","kind":"ClusterImagePolicy","name":"openshift","namespace":"","unmanaged":true}]

# fix: hand ownership back to CVO
oc patch clusterversion version --type json -p '[{"op": "remove", "path": "/spec/overrides"}]'
```

> ⚠️ CVO will reconcile `ClusterImagePolicy/openshift` back to its desired state — any
> manual edits to that object will be reverted. Use a separate `ClusterImagePolicy` CR
> for custom image/registry policies instead of overriding the `openshift` one.

## Autopilot

Overview and enablement (OpenShift Virtualization 4.22 developer preview):

- Introducing virtualization platform autopilot \[[11](#ref-11)\]

Opt in on the HyperConverged CR (`platform.kubevirt.io/autopilot` annotation).
Use `true` for all framework features, or a comma-separated subset (e.g.
`descheduler-loadaware`). The article’s flag names can lag the binary — prefer
the live endpoints below for this cluster’s catalog.

### List features on the cluster

`virt-platform-autopilot` exposes a debug HTTP server on **:8081** inside the
pod. Two endpoints matter:

| Endpoint | Use |
| -------- | --- |
| `/debug/features` | **Full feature catalog** (names, maturity, `opt_in` annotations, requires) |
| `/debug/render` | YAML assets in the **current render** only (what would apply now) — not the full menu |

```bash
AP=$(oc get pod -n openshift-cnv --no-headers | awk '/virt-platform-autopilot/{print $1; exit}')

# Full catalog (authoritative for this image)
oc exec -n openshift-cnv "$AP" -- curl -s http://127.0.0.1:8081/debug/features

# Current render asset list (subset / context-filtered)
oc exec -n openshift-cnv "$AP" -- curl -s http://127.0.0.1:8081/debug/render \
  | grep -E '^# (Asset|Path|Component|Status):'
```

Or port-forward and curl from the laptop:

```bash
oc port-forward -n openshift-cnv deploy/virt-platform-autopilot 8081:8081
curl -s http://localhost:8081/debug/features
curl -s http://localhost:8081/debug/render | grep '^# Asset:'
```

Example `/debug/features` excerpt (vlan615, 2026-10-26) — abbreviated:

```yaml
features:
- name: Load-Aware Descheduler
  install: always
  maturity: TP
  opt_in: null
  requires: [Kube Descheduler Operator]
- name: Swap Enablement
  install: always
  maturity: TP
  opt_in: null
- name: Observability Enhancements
  install: always
  maturity: TP
  opt_in: null
  requires: [Cluster Observability Operator]
- name: Kernel Samepage Merging (KSM) zero pages only
  install: opt-in
  maturity: DP
  opt_in: platform.kubevirt.io/enable-ksm-zero-only=true, hcoUnconfigured:spec.virtualization.ksmConfiguration
- name: Transparent Huge Pages (THP) Tuning
  install: opt-in
  maturity: DP
  opt_in: platform.kubevirt.io/enable-thp-tuning=true, platform.kubevirt.io/enable-thp-tuning-kernelcore=true
# ... also: In-Flight Operations, Kubelet Performance, CPU Manager,
#     KubeVirt Metrics Exporter, MTV, MetalLB, PCI Passthrough
framework:
  maturity: DP
  opt_in: platform.kubevirt.io/autopilot=true
```

Reading the fields:

- `install: always` — enabled with the autopilot framework (no separate feature
  annotation); `opt_in: null`.
- `install: opt-in` — needs the listed `platform.kubevirt.io/enable-…` (and any
  `requires` / `hcoUnconfigured` constraints).
- `framework.opt_in` — master switch (`autopilot=true` or a named subset).

Same day, `/debug/render` on this cluster listed only 11 assets (e.g.
`descheduler-loadaware`, `swap-enable`, `psi-enable`, `prometheus-alerts`,
dashboards) — useful for dry-run YAML, **incomplete** as a feature inventory.
Example render headers when annotation is `descheduler-loadaware`:

```text
# Asset: hco-golden-config
# Asset: descheduler-loadaware
# Asset: metrics-service
# Asset: prometheus-alerts
# Asset: autopilot-dashboard
# Asset: descheduler-dashboard
# Asset: swap-enable
# Asset: psi-enable
# Asset: psi-enable-master
# Asset: metrics-servicemonitor
# Asset: monitoring-ui-plugin
```

Baseline on vlan615 (before enable, 2026-10-13):

```bash
oc get deploy virt-platform-autopilot -n openshift-cnv
oc get hco kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.metadata.annotations}{"\n"}'
```

```text
NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
virt-platform-autopilot   1/1     1            1           23m

{"deployOVS":"false"}   # no platform.kubevirt.io/autopilot annotation yet
```

On vlan615 (2026-10-19) **descheduler-loadaware** was enabled via autopilot
(FPR is HCO default). Later **ksm-zero-only** was added to the same subset —
see [KSM](#ksm-kernel-samepage-merging):

```bash
oc annotate hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  platform.kubevirt.io/autopilot=descheduler-loadaware --overwrite
```

Resulting HCO annotations (descheduler only, before KSM):

```text
{"deployOVS":"false","platform.kubevirt.io/autopilot":"descheduler-loadaware"}
```

Autopilot then installs/reconciles the Kube Descheduler Operator and related objects (labeled `platform.kubevirt.io/managed-by: virt-platform-autopilot`). See [Descheduler (load-aware)](#descheduler-load-aware).

## SWAP

Worker swap for higher VM density. Autopilot can manage enablement
(`swap-enable` / [List features on the cluster](#list-features-on-the-cluster))
once dedicated swap storage exists; the steps below provision that storage on
vlan615 workers (single free NVMe → GPT partition labeled `OCPSWAP`).

### Create partition

Run from the bastion. Requires [Worker SSH](#worker-ssh-bastion-key) (`ssh
core@<worker>`). If SSH is not available, adapt to `oc debug node`. Assumes
**exactly one** free NVMe (no mountpoints) per node — the script refuses 0 or
2+.

It finds that NVMe, creates a GPT swap partition (`PARTLABEL=OCPSWAP`), runs
`mkswap`, briefly `swapon`s to smoke-test, then `swapoff`s (persistent on is
left to autopilot / node config).

```bash
#!/bin/bash

rscript=

read -r -d '' rscript <<'EOF' || true
#!/bin/bash

set -eu
label=OCPSWAP
part=/dev/disk/by-partlabel/$label

trap 'if [[ -n "${lsblk:-}" && -f "$lsblk" ]] ; then rm -f "$lsblk" ; fi; exit' EXIT INT HUP TERM

create_ocpswap() {

    lsblk=$(mktemp -t 'lsblk.XXXXXX')

    cat > "$lsblk" <<'EOP'
#!/usr/bin/python3

import json
import sys
from pathlib import Path
import subprocess

def get_children(dev, rootdev, level=0):
    try:
        wwn = dev['wwn']
        tran = dev['tran']
        if tran == 'nvme':
            for mp in dev['mountpoints']:
                if mp is None:
                    dev = Path(f'/dev/disk/by-id/nvme-{wwn}')
                    if dev.is_block_device():
                        print(dev)
    except (KeyboardInterrupt, BrokenPipeError):
        sys.exit()
    except KeyError:
        pass

try:
    result = subprocess.run(['lsblk', '-O', '-J'], capture_output=True, text=True)
    data = json.loads(result.stdout)['blockdevices']
    for dev in data:
        try:
            get_children(dev, dev['name'])
        except KeyError:
            pass
except (KeyboardInterrupt, BrokenPipeError):
    sys.exit()
except Exception as exc:
    print(f'Unable to retrieve block device information: {exc}')
    sys.exit(1)
EOP

    chmod +x "$lsblk"
    declare -a devices=()
    readarray -t devices <<< "$("$lsblk")"

    case "${#devices[@]}" in
	0)
	    echo "No valid NVMe devices found"
	    return 1
	    ;;
	1)
	    dev="${devices[0]}"
	    echo "Labeling/partitioning $dev"
	    echo -e "label:gpt\nname=$label, type=swap" | sfdisk --wipe=always "$dev"
	    set +x
	    retries=12
	    until [[ -e "$part" ]] ; do
		echo "Waiting for $part to appear"
		if ((retries-- <= 0)) ; then
		    echo "$part not present after 60 seconds"
		    return 1
		else
		    sleep 5
		fi
	    done
	    ;;
	*)
	    echo "More than one valid NVMe device found"
	    return 1
	    ;;
    esac
}

if [[ ! -e "$part" ]] ; then
    create_ocpswap || exit 1
fi

echo "Creating swap"
mkswap -L "$label" "$part"
echo "Testing swap"
swapon "$part"
free | grep -i swap || true
swapoff "$part"
EOF

declare nodes=()

if [[ -n "$*" ]] ; then
    nodes=("$@")
else
    readarray -t nodes <<< "$(oc get node --no-headers | grep worker | awk '{print $1}')"
fi
    
trap 'exit 1' INT HUP TERM
for node in "${nodes[@]}" ; do
    echo "$node"
    ssh "core@$node" sudo bash - <<< "$rscript"
done
```

Optional: pass node names as args; otherwise all workers from `oc get node`.

### Enable via Autopilot

Swap Enablement (`swap-enable` asset) has `install: always` and `opt_in: null`
— it is applied automatically once the autopilot framework is opted in (no
extra feature annotation needed). Adding `swap-enable` to the subset name has
no effect; it only needs the framework annotation to include any value that
activates autopilot (e.g. `descheduler-loadaware` or `true`).

```bash
# If not already set, opt in to the autopilot framework:
oc annotate hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  platform.kubevirt.io/autopilot=descheduler-loadaware --overwrite
```

Autopilot then applies MachineConfig `90-worker-swap-online` (labeled
`platform.kubevirt.io/managed-by=virt-platform-autopilot`) which enables swap
persistently on workers. The worker MCP rolls out (reboot required); after
that, `swapon --show` shows the OCPSWAP partition permanently active.

Confirm MachineConfig and MCP:

```bash
oc get mc 90-worker-swap-online --show-labels
oc get mcp worker
```

Example output (vlan615, 2026-10-19):

```text
NAME                    GENERATEDBYCONTROLLER   IGNITIONVERSION   AGE   LABELS
90-worker-swap-online                           3.5.0             10d   machineconfiguration.openshift.io/role=worker,platform.kubevirt.io/managed-by=virt-platform-autopilot

NAME     CONFIG                                             UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
worker   rendered-worker-...                               True      False      False      9              9                   9                     0                      13d
```

### Verify swap is enabled

**Partition present** (after create; swap may still be off if the script’s
final `swapoff` ran):

```bash
ssh core@d37-h14-000-r660 sudo bash -c \
  'ls -l /dev/disk/by-partlabel/OCPSWAP; lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTLABEL | grep -iE "swap|nvme|NAME" || true'

# or: oc debug node/d37-h14-000-r660 -- chroot /host …
```

Example output (vlan615 / `d37-h14-000-r660`, 2026-10-26):

```text
lrwxrwxrwx. 1 root root 15 Oct 19 13:40 /dev/disk/by-partlabel/OCPSWAP -> ../../nvme0n1p1
NAME                                                                                SIZE TYPE FSTYPE      PARTLABEL
nvme0n1                                                                             2.9T disk             
`-nvme0n1p1                                                                         2.9T part swap        OCPSWAP
```

**Swap active** (after autopilot `swap-enable` MachineConfig applied and worker
rebooted — not from the create script's transient smoke test, which calls
`swapoff` before exiting):

```bash
ssh core@d37-h14-000-r660 sudo bash -c 'swapon --show; free -h; cat /proc/swaps'
```

Example output (same node, 2026-10-26 — swap **on** after autopilot rollout):

```text
NAME           TYPE      SIZE  USED PRIO
/dev/nvme0n1p1 partition 2.9T 14.5M  100

               total        used        free      shared  buff/cache   available
Mem:           503Gi        41Gi       454Gi       107Mi        24Gi       462Gi
Swap:          2.9Ti        14Mi       2.9Ti

Filename				Type		Size		Used		Priority
/dev/nvme0n1p1                          partition	3125615936	14848		100
```

`PARTLABEL=OCPSWAP` on `nvme0n1p1` (2.9T); `swapon` / `free` show **2.9Ti** swap active
(small USED is normal). After the create script’s smoke test only — before
autopilot’s MC applies — `swapon --show` returns empty (script ends with `swapoff`).

## FPR (free page reporting)

**Free page reporting (FPR)** is a guest-cooperative reclaim path: the guest OS
(via the virtio balloon driver) tells the hypervisor which pages it has already
freed. The host can then drop the backing RAM and reuse it for other workloads,
without classic balloon inflate/deflate. On OpenShift Virtualization it is
enabled by default for eligible VMs (Linux guest kernel ≥ 5.7 with virtio
balloon) \[[1](#ref-1)\]\[[2](#ref-2)\]\[[3](#ref-3)\].

### Verify from HCO operator config

```bash
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.virtualization.virtualMachineOptions.disableFreePageReporting}{"\n"}'

oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.virtualization.virtualMachineOptions}{"\n"}'
```

Example output (vlan615, 2026-10-26):

```text
false
{"disableFreePageReporting":false,"disableSerialConsoleLog":false}
```

`disableFreePageReporting: false` → FPR enabled cluster-wide for eligible VMs.

### Verify from the guest

On `rhel9-dsverify2-1` (vlan615, 2026-10-26):

```text
[root@rhel9-dsverify2-1 ~]# uname -r
5.14.0-687.5.1.el9_8.x86_64
[root@rhel9-dsverify2-1 ~]# lsmod | grep virtio_balloon
virtio_balloon         28672  0
[root@rhel9-dsverify2-1 ~]# ls -l /sys/bus/virtio/drivers/virtio_balloon/
total 0
--w-------. 1 root root 4096 Oct 26 16:45 bind
lrwxrwxrwx. 1 root root    0 Oct 26 16:45 module -> ../../../../module/virtio_balloon
--w-------. 1 root root 4096 Oct 23 11:22 uevent
--w-------. 1 root root 4096 Oct 26 16:45 unbind
lrwxrwxrwx. 1 root root    0 Oct 26 16:45 virtio5 -> ../../../../devices/pci0000:00/0000:00:03.0/0000:09:00.0/virtio5
[root@rhel9-dsverify2-1 ~]# FEATURES=$(cat /sys/bus/virtio/drivers/virtio_balloon/virtio*/features)
echo "features=$FEATURES"
echo "VIRTIO_BALLOON_F_REPORTING (bit 5)=${FEATURES:5:1}"
features=0100010000000000000000000000110010000000100000000000000000000000
VIRTIO_BALLOON_F_REPORTING (bit 5)=1
[root@rhel9-dsverify2-1 ~]# cat /sys/module/page_reporting/parameters/page_reporting_order
9
```

- Kernel `5.14` (≥ 5.7) supports FPR.
- `virtio_balloon` is loaded and bound to `virtio5`.
- Sysfs `features` bit **5** (`VIRTIO_BALLOON_F_REPORTING`) is `1` — host and guest
  negotiated free page reporting (bit 0 is leftmost in that string) \[[4](#ref-4)\]\[[5](#ref-5)\].
- `page_reporting_order=9` shows the guest page-reporting framework is active \[[3](#ref-3)\].

## KSM (kernel samepage merging)

**Kernel samepage merging (KSM)** is a host-side dedup path: the kernel scans for
identical VM memory pages and merges them to free RAM. Unlike FPR, it does not
need guest cooperation. This lab uses autopilot’s opt-in **KSM zero pages only**
feature (DP) — node-level dedup with adaptive scan rate and `max_ptes_none=0`
when KSM is active. It requires `spec.virtualization.ksmConfiguration`
**unconfigured** (do not set classic HCO KSM). See
[List features on the cluster](#list-features-on-the-cluster). Docs:
\[[6](#ref-6)\]\[[7](#ref-7)\]\[[8](#ref-8)\]\[[9](#ref-9)\]\[[10](#ref-10)\].

### Before enable (baseline)

vlan615 (2026-10-26), before the autopilot KSM opt-in:

`ksmConfiguration` must be absent (empty `{}` is not enough if it was previously
set — remove the field). Confirm it is unset:

```bash
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.virtualization.ksmConfiguration}{"\n"}'
```

```text
# empty (field unset)
```

Workers report classic KubeVirt KSM not enabled:

```bash
oc get nodes -l node-role.kubernetes.io/worker \
  -L kubevirt.io/ksm-enabled,kubevirt.io/ksm-handler-managed
```

```text
NAME               STATUS   ROLES    AGE   VERSION   KSM-ENABLED   KSM-HANDLER-MANAGED
d35-h26-000-r660   Ready    worker   13d   v1.35.8   false
d35-h27-000-r660   Ready    worker   13d   v1.35.8   false
d36-h02-000-r660   Ready    worker   13d   v1.35.8   false
d36-h03-000-r660   Ready    worker   13d   v1.35.8   false
d36-h04-000-r660   Ready    worker   13d   v1.35.8   false
d36-h07-000-r660   Ready    worker   13d   v1.35.8   false
d36-h08-000-r660   Ready    worker   13d   v1.35.8   false
d36-h20-000-r660   Ready    worker   13d   v1.35.8   false
d37-h14-000-r660   Ready    worker   13d   v1.35.8   false
```

On the host (`d36-h07-000-r660`), KSM is off and has merged nothing:

```text
lguoqing@lguoqing-thinkpadp1gen7:~$ oc debug node/d36-h07-000-r660
Starting pod/d36-h07-000-r660-debug-2lsl5 ...
To use host binaries, run `chroot /host`. Instead, if you need to access host namespaces, run `nsenter -a -t 1`.
Pod IP: 10.1.62.13
All commands and output from this session will be recorded in container logs, including credentials and sensitive information passed through the command prompt.
If you don't see a command prompt, try pressing enter.
sh-5.1# chroot /host
sh-5.1# cat /sys/kernel/mm/ksm/run
0
sh-5.1# cat /sys/kernel/mm/ksm/pages_shared
0
sh-5.1# cat /sys/kernel/mm/ksm/pages_sharing
0
```

- `run=0` → kernel KSM disabled on the node.
- `pages_shared` / `pages_sharing` = `0` → no merged pages yet.

### Enable via Autopilot

Three things must be true (from `/debug/features`:
`opt_in: platform.kubevirt.io/enable-ksm-zero-only=true, hcoUnconfigured:spec.virtualization.ksmConfiguration`):

1. **`ksm-zero-only` in the autopilot subset** — add it to
   `platform.kubevirt.io/autopilot` (comma-separated, or use `true` for all).
   The feature opt-in annotation alone is **not** enough when autopilot is
   pinned to a named subset such as `descheduler-loadaware` — the assets appear
   `INCLUDED` in `/debug/render` but reconcile will not apply them.
2. **`platform.kubevirt.io/enable-ksm-zero-only=true`** annotation on HCO.
3. **`spec.virtualization.ksmConfiguration` must be absent** on the HCO CR
   (`hcoUnconfigured` is a precondition on existing cluster state, not an
   annotation to set — do not patch this field).

```bash
# If classic HCO KSM was set earlier, remove it first:
# oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv --type=json \
#   -p '[{"op":"remove","path":"/spec/virtualization/ksmConfiguration"}]'

oc annotate hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  platform.kubevirt.io/autopilot=descheduler-loadaware,ksm-zero-only --overwrite

oc annotate hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  platform.kubevirt.io/enable-ksm-zero-only=true --overwrite
```

### After enable

vlan615 (2026-10-26), right after the annotations above:

```bash
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.metadata.annotations}{"\n"}'
oc get mc 99-worker-ksm-zero-only
oc get mcp worker
```

```text
{"deployOVS":"false","platform.kubevirt.io/autopilot":"descheduler-loadaware,ksm-zero-only","platform.kubevirt.io/enable-ksm-zero-only":"true"}

NAME                      GENERATEDBYCONTROLLER   IGNITIONVERSION   AGE
99-worker-ksm-zero-only                           3.5.0             33s

NAME     CONFIG                                             UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
worker   rendered-worker-b35dca4ec2af7c69c2910a55d56274db   False     True       False      9              0                   0                     0                      13d
```

Autopilot applies MachineConfig `99-worker-ksm-zero-only` (labeled
`platform.kubevirt.io/managed-by=virt-platform-autopilot`) with Ignition files
for `/usr/local/bin/kubevirt-ksm-tune.py` and systemd unit
`kubevirt-ksm-tune.service` (“Configure and enable KSM zero-pages-only mode”).
It also patches `ConfigMap/cluster-monitoring-config` in
`openshift-monitoring` to enable the node-exporter `ksmd` collector:

```text
nodeExporter:
  collectors:
    ksmd:
      enabled: true
```

Worker MCP goes `UPDATING=True` (nodes reboot to pick up the MC). On this
cluster the master twin `99-master-ksm-zero-only` was not created (same pattern
as `psi-enable-master` — asset conditions not met for masters).

Before the MCP rollout finishes, host sysfs is still the baseline (`run=0`,
tune script not installed yet):

```bash
oc debug node/d35-h26-000-r660 -- chroot /host bash -c \
  'echo run=$(cat /sys/kernel/mm/ksm/run); ls /usr/local/bin/kubevirt-ksm-tune.py; systemctl is-active kubevirt-ksm-tune.service'
```

```text
run=0
ls: cannot access '/usr/local/bin/kubevirt-ksm-tune.py': No such file or directory
inactive
```

After workers finish updating, re-check for the tune script / unit and KSM
sysfs (`run`, `pages_shared` / `pages_sharing`, `max_ptes_none`).

**Post-upgrade (5.0.0 / k8s v1.36.5, 2026-10-30)** — annotations and MC name are
**unchanged** in 5.0; the same opt-in procedure applies. Verified state on vlan615
after the 4.x→5.0 upgrade:

```bash
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.metadata.annotations}{"\n"}'
oc get mc 99-worker-ksm-zero-only --show-labels
oc get mcp worker
oc debug node/d36-h07-000-r660 -- chroot /host bash -c \
  'echo run=$(cat /sys/kernel/mm/ksm/run); echo pages_shared=$(cat /sys/kernel/mm/ksm/pages_shared); ls /usr/local/bin/kubevirt-ksm-tune.py'
```

```text
{"deployOVS":"false","platform.kubevirt.io/autopilot":"descheduler-loadaware,ksm-zero-only","platform.kubevirt.io/enable-ksm-zero-only":"true"}

NAME                      GENERATEDBYCONTROLLER   IGNITIONVERSION   AGE     LABELS
99-worker-ksm-zero-only                           3.5.0             3d21h   machineconfiguration.openshift.io/role=worker,platform.kubevirt.io/managed-by=virt-platform-autopilot

NAME     CONFIG                                             UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
worker   rendered-worker-5d8750267fea1a7cf4c898d6a289cbd4   True      False      False      9              9                   9                     0                      17d

run=1
pages_shared=0
/usr/local/bin/kubevirt-ksm-tune.py
```

- `run=1` → KSM active on all workers (tune script applied).
- `pages_shared=0` / `pages_sharing=0` → no identical pages yet (idle cluster, no memory pressure).
- Node labels `kubevirt.io/ksm-enabled=false` are expected — that label is for classic HCO-managed KSM, not autopilot's ksm-zero-only.
- `ksm-zero-only-master` MC is now also `INCLUDED` in `/debug/render` (was absent in 4.22).

> **CNV 5.0 note (per Simone Tiraboschi):** When CNV upgrades to 5.0, autopilot will be
> **on by default** — the `platform.kubevirt.io/autopilot` annotation will no longer be
> required. Only `platform.kubevirt.io/enable-ksm-zero-only=true` will be needed to opt
> in to KSM. This cluster is still on CNV **4.22.12** so the annotation is still required.

## THP (transparent huge pages)

**Host-side sysfs tuning** — the guest OS is unaffected. Autopilot drops
`/usr/local/bin/kubevirt-thp-tune.py` via MachineConfig `99-worker-thp-tuning` and runs
it as a oneshot systemd unit at boot. The script sets the following on the node:

| Sysfs knob | Baseline (RHCOS default) | After autopilot |
| ---------- | ------------------------ | --------------- |
| `transparent_hugepage/enabled` | `[always]` | `madvise` |
| `transparent_hugepage/defrag` | `[madvise]` | `madvise` (unchanged) |
| `transparent_hugepage/shmem_enabled` | `always` | `advise` |
| `transparent_hugepage/shrink_underused` | `1` (CS10/6.12+) | `0` |
| `khugepaged/pages_to_scan` | `4096` | `130000` (fixed) |
| `khugepaged/scan_sleep_millisecs` | `10000` | `1000 + 64000/node_GB` (node-sized) |
| `khugepaged/max_ptes_none` | `0` | `0` if KSM active, else `511` |

Key points from the script source (`assets/active/machine-config/06-thp-tuning/thp-tune.py`):

- **`enabled=madvise`** (not `always`) — only processes that call `madvise(MADV_HUGEPAGE)`
  get THP at fault time. **QEMU does this for guest RAM automatically** — so all VM memory
  gets THP, while system services stay on 4K pages.
- **`shmem_enabled=advise`** — covers memfd-backed guest RAM used by virtiofs/passt
  (shmem, not anonymous memory — needs its own knob).
- **`shrink_underused=0`** — prevents the kernel's deferred underused shrinker from
  splitting freshly collapsed THPs under memory reclaim (CS10 / kernel 6.12+ only).
- **`pages_to_scan=130000`** — ~254 regions/wake (1 region = 512 pages = 2 MB); enough
  budget to re-collapse PMD splits caused by KSM or free-page-reporting.
- **`scan_sleep_millisecs`** — node-sized: `1000 + 64000/node_GB`

  | Node RAM | sleep | Wakes/s | Sweep (80% VM load) |
  |---|---|---|---|
  | 16 GB | 5000 ms | 0.2 | 2.2 min |
  | 64 GB | 2000 ms | 0.5 | 3.4 min |
  | 256 GB | 1250 ms | 0.8 | 8.6 min |
  | 512 GB | 1125 ms | 0.9 | 15.5 min |
  | 1 TB | 1063 ms | 0.9 | 29.3 min |

  vlan615 nodes have **~503 GB RAM** → `sleep ≈ 1127 ms`, `wakes/s ≈ 0.9`.

- **`max_ptes_none`** — coordinated with KSM: `0` when `ksm/run==1` (same logic as
  `ksm-tune.py`; start order doesn't matter).

Opt-in annotations:

| Annotation | Effect | Reboot? |
| ---------- | ------ | ------- |
| `platform.kubevirt.io/enable-thp-tuning=true` | All sysfs/khugepaged tuning above | No |
| `platform.kubevirt.io/enable-thp-tuning-kernelcore=true` | `kernelcore=2G movablecore=97%` — grows `ZONE_MOVABLE` so huge page formation succeeds under pressure | Yes |

### Before enable (baseline)

vlan615 (2026-10-30), before autopilot THP opt-in (`d36-h07-000-r660`):

```bash
oc debug node/d36-h07-000-r660 -- chroot /host bash -c '
echo enabled=$(cat /sys/kernel/mm/transparent_hugepage/enabled)
echo defrag=$(cat /sys/kernel/mm/transparent_hugepage/defrag)
echo scan_sleep_ms=$(cat /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs)
echo alloc_sleep_ms=$(cat /sys/kernel/mm/transparent_hugepage/khugepaged/alloc_sleep_millisecs)
echo pages_to_scan=$(cat /sys/kernel/mm/transparent_hugepage/khugepaged/pages_to_scan)
echo max_ptes_none=$(cat /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none)
grep AnonHugePages /proc/meminfo
grep -o "transparent_hugepage[^ ]*" /proc/cmdline || echo "(not set in cmdline)"
'
```

```text
enabled:   [always] madvise never
defrag:    always defer defer+madvise [madvise] never
scan_sleep_ms:  10000
alloc_sleep_ms: 60000
pages_to_scan:  4096
max_ptes_none:  0
AnonHugePages:  4569088 kB   (~4.4 GiB already collapsed by kernel default)
(not set in cmdline)
```

Key observations (what autopilot will change):

- `enabled=always` → will become **`madvise`** — tightens scope to only QEMU (which
  already calls `MADV_HUGEPAGE` for guest RAM) and removes THP overhead from system services.
- `defrag=madvise` — already correct, unchanged.
- `pages_to_scan=4096` → will become **`130000`** — 32× more scanning budget per wake.
- `scan_sleep_ms=10000` → will become **`~1127 ms`** (503 GB node) — 9× more frequent wakes.
- `max_ptes_none=0` — already `0` (KSM is active); unchanged.
- `kernelcore` not set → `ZONE_MOVABLE` small; needs `enable-thp-tuning-kernelcore` (reboot) to fix.
- `HugePages_Total=0` — no static (hugetlbfs) huge pages; THP is the only huge page path here.

### Enable via Autopilot

Two things required — same pattern as KSM:

1. **`thp-tuning` in the autopilot subset** — add it to `platform.kubevirt.io/autopilot`.
2. **`platform.kubevirt.io/enable-thp-tuning=true`** annotation on HCO — satisfies the
   asset condition in `metadata.yaml`.

```bash
oc annotate hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  platform.kubevirt.io/autopilot=descheduler-loadaware,ksm-zero-only,thp-tuning --overwrite

oc annotate hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  platform.kubevirt.io/enable-thp-tuning=true --overwrite
```

> ⚠️ **Reboot required.** Unlike KSM (which has a `MachineConfiguration` Node Disruption
> Policy that restarts only the systemd service), THP has no NDP asset — MCO defaults to
> cordon → reboot for each worker. Expect a full rolling reboot across all workers.

Autopilot applies `99-worker-thp-tuning` MC (labeled
`platform.kubevirt.io/managed-by=virt-platform-autopilot`). Verify:

```bash
oc get mc 99-worker-thp-tuning --show-labels
oc get mcp worker
```

Example output (vlan615, 2026-10-30):

```text
NAME                   GENERATEDBYCONTROLLER   IGNITIONVERSION   AGE   LABELS
99-worker-thp-tuning                           3.5.0             8s    machineconfiguration.openshift.io/role=worker,platform.kubevirt.io/managed-by=virt-platform-autopilot

NAME     CONFIG                                             UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
worker   rendered-worker-c9edd235927a1713b115f117ef5cb96f   False     True       False      9              0                   0                     0                      17d
```

After MCP rollout, verify on a node:

```bash
oc debug node/d37-h14-000-r660 -- chroot /host bash -c '
echo enabled=$(cat /sys/kernel/mm/transparent_hugepage/enabled)
echo defrag=$(cat /sys/kernel/mm/transparent_hugepage/defrag)
echo shmem_enabled=$(cat /sys/kernel/mm/transparent_hugepage/shmem_enabled 2>/dev/null || echo n/a)
echo shrink_underused=$(cat /sys/kernel/mm/transparent_hugepage/shrink_underused 2>/dev/null || echo n/a)
echo pages_to_scan=$(cat /sys/kernel/mm/transparent_hugepage/khugepaged/pages_to_scan)
echo scan_sleep_ms=$(cat /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs)
echo max_ptes_none=$(cat /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none)
systemctl is-active kubevirt-thp-tune.service
journalctl -u kubevirt-thp-tune.service --no-pager -n 3
grep AnonHugePages /proc/meminfo
'
```

Example output (vlan615, `d37-h14-000-r660`, 2026-10-30):

```text
enabled=always [madvise] never
defrag=always defer defer+madvise [madvise] never
shmem_enabled=always within_size advise [never] deny force
shrink_underused=n/a
pages_to_scan=130000
scan_sleep_ms=1127
max_ptes_none=0
active
Oct 30 20:07:37 d37-h14-000-r660 systemd[1]: Starting Configure THP madvise/defrag mode, khugepaged scan rate, and max_ptes_none...
Oct 30 20:07:37 d37-h14-000-r660 kubevirt-thp-tune.py[2982]: thp-tune: node=503GB enabled=madvise defrag=madvise pages_to_scan=130000 sleep=1127ms regions/s=224 max_ptes_none=0 (ksm active)
Oct 30 20:07:37 d37-h14-000-r660 systemd[1]: Finished Configure THP madvise/defrag mode, khugepaged scan rate, and max_ptes_none...
AnonHugePages:         0 kB
```

Key results:

- `enabled=[madvise]` — changed from `[always]`; only QEMU (which calls `MADV_HUGEPAGE` for guest RAM) gets THP.
- `shmem_enabled=[never]` — note: kernel shows current selection; autopilot set it to `advise` but RHCOS kernel may not support this knob — `shrink_underused=n/a` confirms the same (kernel 6.12+ only).
- `pages_to_scan=130000` — up from 4096 (32×).
- `scan_sleep_ms=1127` — down from 10000; formula `1000 + 64000/503 = 1127 ms` for 503 GB node.
- `max_ptes_none=0` — unchanged (KSM active).
- `AnonHugePages=0 kB` — expected on an idle node with no VMs running; will increase once QEMU processes start and khugepaged scans their mappings.

## Descheduler (load-aware)

Captured from `oc` against vlan615 (2026-10-19). Autopilot owns the operand CRs; do not hand-edit them unless you intend to fight reconciliation.

### Enable via autopilot

1. Ensure CNV / HCO is healthy and `virt-platform-autopilot` is Running.
2. Annotate HCO with `descheduler-loadaware` (or include it in a multi-flag value such as `true`).
3. Wait for CSV `clusterkubedescheduleroperator` in `openshift-kube-descheduler-operator`, then `KubeDescheduler/cluster`, deployments `descheduler` + `softtainter`, MachineConfig `99-openshift-machineconfig-worker-psi-karg`, and worker MCP rollout (`psi=1` requires reboot).

```bash
oc get csv -n openshift-kube-descheduler-operator
oc get kubedescheduler -n openshift-kube-descheduler-operator
oc get deploy -n openshift-kube-descheduler-operator
oc get mc 99-openshift-machineconfig-worker-psi-karg
oc get mcp worker
```

Example output (vlan615, 2026-10-19):

```text
NAME                                    DISPLAY                     VERSION   RELEASE   REPLACES                                PHASE
clusterkubedescheduleroperator.v5.4.3   Kube Descheduler Operator   5.4.3               clusterkubedescheduleroperator.v5.3.0   Succeeded

NAME      AGE
cluster   5h41m

NAME                   READY   UP-TO-DATE   AVAILABLE   AGE
descheduler            1/1     1            1           5h19m
descheduler-operator   1/1     1            1           5h41m
softtainter            1/1     1            1           5h19m

NAME                                         GENERATEDBYCONTROLLER   IGNITIONVERSION   AGE
99-openshift-machineconfig-worker-psi-karg                                             5h41m

NAME     CONFIG                                             UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
worker   rendered-worker-b35dca4ec2af7c69c2910a55d56274db   True      False      False      9              9                   9                     0                      6d3h
```

### KubeDescheduler instance

```bash
oc get kubedescheduler cluster -n openshift-kube-descheduler-operator -o yaml
```

Example output (vlan615, 2026-10-19):

```yaml
apiVersion: operator.openshift.io/v1
kind: KubeDescheduler
metadata:
  creationTimestamp: "2026-10-19T13:34:52Z"
  generation: 3
  labels:
    platform.kubevirt.io/managed-by: virt-platform-autopilot
  name: cluster
  namespace: openshift-kube-descheduler-operator
spec:
  deschedulingIntervalSeconds: 60
  evictionLimits:
    node: 2
    total: 5
  logLevel: Normal
  managementState: Managed
  mode: Automatic
  operatorLogLevel: Normal
  profileCustomizations:
    devActualUtilizationProfile: PrometheusCPUMemoryCombinedProfile
  profiles:
  - KubeVirtRelieveAndMigrate
  unsupportedConfigOverrides: null
status:
  conditions:
  - lastTransitionTime: "2026-10-19T13:34:52Z"
    status: "False"
    type: ResourceSyncControllerDegraded
  - lastTransitionTime: "2026-10-19T13:56:11Z"
    status: "False"
    type: TargetConfigControllerDegraded
  - lastTransitionTime: "2026-10-19T13:34:56Z"
    status: "False"
    type: ConfigObservationDegraded
  generations:
  - group: apps
    lastGeneration: 2
    name: descheduler
    namespace: openshift-kube-descheduler-operator
    resource: deployments
  - group: apps
    lastGeneration: 2
    name: softtainter
    namespace: openshift-kube-descheduler-operator
    resource: deployments
```

(`observedConfig.servingInfo` cipher suite list omitted above; present on the live CR.)

Important `spec` fields:

| Field | Value | Notes |
| ----- | ----- | ----- |
| `managementState` | `Managed` | Operator owns deployments |
| `mode` | `Automatic` | Evicts (not Predictive-only) |
| `profiles` | `KubeVirtRelieveAndMigrate` | Load-aware relieve/migrate for KubeVirt |
| `profileCustomizations.devActualUtilizationProfile` | `PrometheusCPUMemoryCombinedProfile` | Uses Prometheus util + PSI pressure |
| `deschedulingIntervalSeconds` | `60` | Operand `--descheduling-interval=60s` |
| `evictionLimits.node` / `.total` | `2` / `5` | Caps per cycle |

Label: `platform.kubevirt.io/managed-by: virt-platform-autopilot`.

Operand args (deployment `descheduler`): policy file `/policy-dir/policy.yaml`, `--feature-gates=EvictionsInBackground=true`, TLS serving certs. Soft-tainter uses the same policy ConfigMap.

### PSI kernel argument

Load-aware profile expects PSI metrics (`node_pressure_*`). Autopilot applies MachineConfig `99-openshift-machineconfig-worker-psi-karg`. Confirm on a worker:

```bash
oc get mc 99-openshift-machineconfig-worker-psi-karg -o yaml
oc debug node/d37-h14-000-r660 -- chroot /host grep -o 'psi=1' /proc/cmdline
```

Example output (vlan615, 2026-10-19):

`oc get mc 99-openshift-machineconfig-worker-psi-karg -o yaml`:

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  creationTimestamp: "2026-10-19T13:34:52Z"
  generation: 1
  labels:
    machineconfiguration.openshift.io/role: worker
    platform.kubevirt.io/managed-by: virt-platform-autopilot
  name: 99-openshift-machineconfig-worker-psi-karg
  resourceVersion: "5867076"
  uid: 476cd49d-fd0d-4e1a-a181-47de16f6ac1e
spec:
  kernelArguments:
  - psi=1
```

`oc debug node/d37-h14-000-r660 -- chroot /host grep -o 'psi=1' /proc/cmdline`:

```text
Starting pod/d37-h14-000-r660-debug-557cx ...
To use host binaries, run `chroot /host`. Instead, if you need to access host namespaces, run `nsenter -a -t 1`.
psi=1

Removing debug pod ...
```

All 9 vlan615 workers show `psi=1` on `/proc/cmdline` and expose `/proc/pressure/{cpu,io,irq,memory}`.

Alert `DeschedulerPSIDisabled` (`PrometheusRule/descheduler-psi-alert`) fires if workers lack PSI while the utilization profile needs it.

### Policy / Prometheus metrics

Operator materializes policy in ConfigMap `cluster` (`policy.yaml`):

```bash
oc get cm cluster -n openshift-kube-descheduler-operator -o yaml
```

Example output (vlan615, 2026-10-19; `evictableNamespaces.exclude` truncated):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster
  namespace: openshift-kube-descheduler-operator
  ownerReferences:
  - apiVersion: operator.openshift.io/v1
    kind: KubeDescheduler
    name: cluster
data:
  policy.yaml: |
    apiVersion: descheduler/v1alpha2
    kind: DeschedulerPolicy
    maxNoOfPodsToEvictPerNode: 2
    maxNoOfPodsToEvictTotal: 5
    metricsProviders:
    - prometheus:
        url: https://prometheus-k8s-openshift-monitoring.apps.vlan615.rdu2.scalelab.redhat.com
      source: Prometheus
    nodeSelector: kubevirt.io/schedulable=true
    profiles:
    - name: KubeVirtRelieveAndMigrate
      pluginConfig:
      - args:
          evictableNamespaces:
            exclude:
            - kube-system
            - hypershift
            - openshift
            - openshift-cnv
            # ... full openshift-* / system list on cluster ...
          evictionLimits:
            node: 2
          metricsUtilization:
            prometheus:
              query: descheduler:node:linear_amplified_ideal_point_positive_distance:k3:avg1m
            source: Prometheus
          targetThresholds:
            MetricResource: 10
          thresholds:
            MetricResource: 0
          useDeviationThresholds: true
        name: LowNodeUtilization
      - args:
          evictLocalStoragePods: true
          noEvictionPolicy: Mandatory
          podProtections: {}
        name: DefaultEvictor
      plugins:
        balance:
          enabled:
          - LowNodeUtilization
        filter:
          enabled:
          - DefaultEvictor
```

| Setting | Value |
| ------- | ----- |
| Profile plugins | `LowNodeUtilization` (balance) + `DefaultEvictor` (filter) |
| `nodeSelector` | `kubevirt.io/schedulable=true` |
| Metrics source | Prometheus (`prometheus-k8s` route in `openshift-monitoring`) |
| Utilization query | `descheduler:node:linear_amplified_ideal_point_positive_distance:k3:avg1m` |
| Thresholds | `MetricResource` low `0`, target `10`; `useDeviationThresholds: true` |
| Eviction limits in policy | `maxNoOfPodsToEvictPerNode: 2`, `maxNoOfPodsToEvictTotal: 5` |

`PrometheusRule/descheduler-rules` (30s interval) builds recording rules: CPU/memory utilization, PSI pressure (`descheduler:nodepressure:{cpu,memory}:avg1m`), positive deviations, then the k3-amplified ideal-point distance used as the descheduler metric (`clamp_max(3 * distance, 1.0)`).

### Verify

```bash
oc get kubedescheduler cluster -n openshift-kube-descheduler-operator -o jsonpath='{.spec}{"\n"}'
oc get cm cluster -n openshift-kube-descheduler-operator -o jsonpath='{.data.policy\.yaml}'
oc get prometheusrules -n openshift-kube-descheduler-operator
oc logs -n openshift-kube-descheduler-operator deploy/descheduler --tail=50
oc get mc 99-openshift-machineconfig-worker-psi-karg -o yaml
oc get csv -n openshift-kube-descheduler-operator
oc get deploy -n openshift-kube-descheduler-operator
oc get mcp worker
oc debug node/d37-h14-000-r660 -- chroot /host grep -o 'psi=1' /proc/cmdline
```

Example output (vlan615, 2026-10-19):

`KubeDescheduler` `.spec` (jsonpath; `observedConfig` present on cluster):

```json
{
  "deschedulingIntervalSeconds": 60,
  "evictionLimits": {"node": 2, "total": 5},
  "logLevel": "Normal",
  "managementState": "Managed",
  "mode": "Automatic",
  "operatorLogLevel": "Normal",
  "profileCustomizations": {
    "devActualUtilizationProfile": "PrometheusCPUMemoryCombinedProfile"
  },
  "profiles": ["KubeVirtRelieveAndMigrate"],
  "unsupportedConfigOverrides": null
}
```

`policy.yaml` matches the ConfigMap above (Prometheus URL, query, thresholds 0/10, limits 2/5).

```text
NAME                    AGE
descheduler-psi-alert   5h19m
descheduler-rules       5h19m

NAME                                    DISPLAY                     VERSION   RELEASE   REPLACES                                PHASE
clusterkubedescheduleroperator.v5.4.3   Kube Descheduler Operator   5.4.3               clusterkubedescheduleroperator.v5.3.0   Succeeded

NAME                   READY   UP-TO-DATE   AVAILABLE   AGE
descheduler            1/1     1            1           5h19m
descheduler-operator   1/1     1            1           5h41m
softtainter            1/1     1            1           5h19m

NAME     CONFIG                                             UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
worker   rendered-worker-b35dca4ec2af7c69c2910a55d56274db   True      False      False      9              9                   9                     0                      6d3h

psi=1
```

Descheduler logs (idle cluster — underutilized=7, appropriately utilized=`d36-h07`/`d37-h14`, overutilized=0, no evictions):

```text
I1019 19:15:15.618936       1 lownodeutilization.go:236] "Node has been classified" plugin="LowNodeUtilization" ExtensionPoint="Balance" category="underutilized" node="d35-h27-000-r660" usage={"MetricResource":"0"} usagePercentage={"MetricResource":0}
I1019 19:15:15.618969       1 lownodeutilization.go:236] "Node has been classified" plugin="LowNodeUtilization" ExtensionPoint="Balance" category="underutilized" node="d36-h04-000-r660" usage={"MetricResource":"0"} usagePercentage={"MetricResource":0}
I1019 19:15:15.618977       1 lownodeutilization.go:236] "Node has been classified" plugin="LowNodeUtilization" ExtensionPoint="Balance" category="underutilized" node="d36-h20-000-r660" usage={"MetricResource":"0"} usagePercentage={"MetricResource":0}
I1019 19:15:15.618983       1 lownodeutilization.go:236] "Node has been classified" plugin="LowNodeUtilization" ExtensionPoint="Balance" category="underutilized" node="d35-h26-000-r660" usage={"MetricResource":"0"} usagePercentage={"MetricResource":0}
I1019 19:15:15.618988       1 lownodeutilization.go:236] "Node has been classified" plugin="LowNodeUtilization" ExtensionPoint="Balance" category="underutilized" node="d36-h02-000-r660" usage={"MetricResource":"0"} usagePercentage={"MetricResource":0}
I1019 19:15:15.618993       1 lownodeutilization.go:236] "Node has been classified" plugin="LowNodeUtilization" ExtensionPoint="Balance" category="underutilized" node="d36-h08-000-r660" usage={"MetricResource":"0"} usagePercentage={"MetricResource":0}
I1019 19:15:15.618998       1 lownodeutilization.go:236] "Node has been classified" plugin="LowNodeUtilization" ExtensionPoint="Balance" category="underutilized" node="d36-h03-000-r660" usage={"MetricResource":"0"} usagePercentage={"MetricResource":0}
I1019 19:15:15.619015       1 lownodeutilization.go:295] "Node is appropriately utilized" plugin="LowNodeUtilization" ExtensionPoint="Balance" node="d36-h07-000-r660" usage={"MetricResource":"4"} usagePercentage={"MetricResource":4}
I1019 19:15:15.619024       1 lownodeutilization.go:295] "Node is appropriately utilized" plugin="LowNodeUtilization" ExtensionPoint="Balance" node="d37-h14-000-r660" usage={"MetricResource":"3"} usagePercentage={"MetricResource":3}
I1019 19:15:15.619032       1 lownodeutilization.go:307] "Criteria for a node under utilization" plugin="LowNodeUtilization" ExtensionPoint="Balance" MetricResource="0.00%"
I1019 19:15:15.619037       1 lownodeutilization.go:308] "Number of underutilized nodes" plugin="LowNodeUtilization" ExtensionPoint="Balance" totalNumber=7
I1019 19:15:15.619041       1 lownodeutilization.go:309] "Criteria for a node above target utilization" plugin="LowNodeUtilization" ExtensionPoint="Balance" MetricResource="10.00%"
I1019 19:15:15.619045       1 lownodeutilization.go:310] "Number of overutilized nodes" plugin="LowNodeUtilization" ExtensionPoint="Balance" totalNumber=0
I1019 19:15:15.619048       1 lownodeutilization.go:334] "All nodes are under target utilization, nothing to do here" plugin="LowNodeUtilization" ExtensionPoint="Balance"
I1019 19:15:15.619063       1 profile.go:417] "Total number of evictions/requests" extension point="Balance" evictedPods=0 evictionRequests=0
I1019 19:15:15.619073       1 descheduler.go:252] "Number of evictions/requests" totalEvicted=0 evictionRequests=0
```

## Alerting dashboard (KContext)

Lab instance of [KContext](https://github.com/gqlo/KContext) — Alertmanager alerts ingested into Redis and browsable on an HTML dashboard (filters by severity, status, namespace, time range).

| | |
| --- | ----- |
| URL | [http://f24-h03-000-r670.rdu2.scalelab.redhat.com:8083/](http://f24-h03-000-r670.rdu2.scalelab.redhat.com:8083/) |
| Host | `f24-h03-000-r670` (Scale Lab bastion) |
| Listen | `:8083` (`LISTEN_ADDR`) |

Reachable from the lab network. Service install/ops: `KContext/utils/install-kcontext.sh` and [KContext docs](https://github.com/gqlo/KContext/blob/main/docs/dashboard.md).

## References

1. <a id="ref-1"></a>[Red Hat OpenShift Virtualization memory management overview](https://developers.redhat.com/articles/2026/10/15/red-hat-openshift-virtualization-memory-management-overview#guest-cooperative-memory-reclamation) — FPR / guest-cooperative reclaim (2026-10-15)
2. <a id="ref-2"></a>[Save memory with OpenShift Virtualization using Free Page Reporting](https://developers.redhat.com/articles/2024/03/13/save-memory-openshift-virtualization-using-free-page-reporting) — (2024-03-13)
3. <a id="ref-3"></a>[Kernel free page reporting](https://docs.kernel.org/mm/free_page_reporting.html)
4. <a id="ref-4"></a>[How to check VIRTIO feature bits inside Linux guests](http://blog.vmsplice.net/2020/05/how-to-check-virtio-feature-bits-inside.html)
5. <a id="ref-5"></a>[Linux `virtio_balloon.h`](https://github.com/torvalds/linux/blob/master/include/uapi/linux/virtio_balloon.h) — `VIRTIO_BALLOON_F_REPORTING` = 5
6. <a id="ref-6"></a>[Activating kernel samepage merging (KSM)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/virtualization/nodes#virt-activating-ksm) — OCP: activate on memory overload; `ksm-handler-managed` when CNV flips KSM on
7. <a id="ref-7"></a>[OpenShift Virtualization 4.15 release notes (KSM)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.15/html/virtualization/release-notes) — activate KSM when a node is overloaded
8. <a id="ref-8"></a>[KubeVirt KSM Management](https://kubevirt.io/user-guide/cluster_admin/ksm/)
9. <a id="ref-9"></a>[KubeVirt PR #10477 — KSM according to memory pressure](https://github.com/kubevirt/kubevirt/pull/10477)
10. <a id="ref-10"></a>[KubeVirt PR #11306 — `ksm-enabled` label = managed/configured, not live `run`](https://github.com/kubevirt/kubevirt/pull/11306)
11. <a id="ref-11"></a>[Introducing virtualization platform autopilot](https://developers.redhat.com/articles/2026/05/07/introducing-virtualization-platform-autopilot) — (2026-05-07)
12. <a id="ref-12"></a>[Red Hat Solution 6994678 — "ClusterVersionUpgradeable" failed because of "ClusterVersionOverridesSet"](https://access.redhat.com/solutions/6994678) — remove `spec.overrides` to unblock upgrades
