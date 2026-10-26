# Memory tiering — env and install

**Last Updated:** 2026-10-26

Cluster / lab environment and install path for the memory-tiering feature stack
(swap, KSM zero pages, FPR, descheduler, autopilot).

## Catalog

<!-- If you don't use emacs, you can edit this manually -->
<!-- markdown-toc start - Don't edit this section. Run M-x markdown-toc-refresh-toc -->
**Table of Contents**

- [Memory tiering — env and install](#memory-tiering--env-and-install)
  - [Catalog](#catalog)
  - [Goal](#goal)
  - [Cluster installation](#cluster-installation)
  - [Environment](#environment)
    - [Worker SSH (bastion key)](#worker-ssh-bastion-key)
      - [`worker-ssh-key-mcp.yaml`](#worker-ssh-key-mcpyaml)
      - [Verify](#verify)
    - [CNV installation](#cnv-installation)
    - [LVMCluster (LVMS / SSD)](#lvmcluster-lvms--ssd)
      - [LVMCluster CR](#lvmcluster-cr)
      - [Verify](#verify-1)
  - [Autopilot](#autopilot)
    - [List features on the cluster](#list-features-on-the-cluster)
  - [SWAP](#swap)
  - [FPR (free page reporting)](#fpr-free-page-reporting)
    - [Verify from HCO operator config](#verify-from-hco-operator-config)
    - [Verify from the guest](#verify-from-the-guest)
  - [KSM (kernel samepage merging)](#ksm-kernel-samepage-merging)
    - [Before enable (baseline)](#before-enable-baseline)
    - [Enable via HCO](#enable-via-hco)
    - [After enable](#after-enable)
  - [Descheduler (load-aware)](#descheduler-load-aware)
    - [Enable via autopilot](#enable-via-autopilot)
    - [KubeDescheduler instance](#kubedescheduler-instance)
    - [PSI kernel argument](#psi-kernel-argument)
    - [Policy / Prometheus metrics](#policy--prometheus-metrics)
    - [Verify](#verify-2)
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

#### `worker-ssh-key-mcp.yaml`

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

#### Verify

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

#### LVMCluster CR

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

#### Verify

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

## Autopilot

Overview and enablement (OpenShift Virtualization 4.22 developer preview):

- [Introducing virtualization platform autopilot](https://developers.redhat.com/articles/2026/05/07/introducing-virtualization-platform-autopilot) (Red Hat Developer, 2026-05-07)

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

On vlan615 (2026-10-19) only **descheduler-loadaware** was enabled via autopilot
so far (swap still pending via autopilot; FPR is HCO default; classic KSM via
HCO `ksmConfiguration` — see [KSM](#ksm-kernel-samepage-merging); autopilot also
offers opt-in **KSM zero pages only** via
`platform.kubevirt.io/enable-ksm-zero-only=true`):

```bash
oc annotate hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  platform.kubevirt.io/autopilot=descheduler-loadaware --overwrite
```

Resulting HCO annotations:

```text
{"deployOVS":"false","platform.kubevirt.io/autopilot":"descheduler-loadaware"}
```

Autopilot then installs/reconciles the Kube Descheduler Operator and related objects (labeled `platform.kubevirt.io/managed-by: virt-platform-autopilot`). See [Descheduler (load-aware)](#descheduler-load-aware).

## SWAP

Run this script from the bastion. It requires ssh to have been set up;
if it isn't, it wouldn't be hard to modify this script to use `oc
debug node`. It assumes that there is a single free NVMe drive and
sets up a swap partition which it then check by running free (you have
to look at the output at least for now):

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

## FPR (free page reporting)

**Free page reporting (FPR)** is a guest-cooperative reclaim path: the guest OS
(via the virtio balloon driver) tells the hypervisor which pages it has already
freed. The host can then drop the backing RAM and reuse it for other workloads,
without classic balloon inflate/deflate. On OpenShift Virtualization it is
enabled by default for eligible VMs (Linux guest kernel ≥ 5.7 with virtio
balloon).

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
  negotiated free page reporting (bit 0 is leftmost in that string).
- `page_reporting_order=9` shows the guest page-reporting framework is active.

References:

- [How to check VIRTIO feature bits inside Linux guests](http://blog.vmsplice.net/2020/05/how-to-check-virtio-feature-bits-inside.html)
- [Linux `virtio_balloon.h`](https://github.com/torvalds/linux/blob/master/include/uapi/linux/virtio_balloon.h) — `VIRTIO_BALLOON_F_REPORTING` = 5
- [Kernel free page reporting](https://docs.kernel.org/mm/free_page_reporting.html)
- [Save memory with Free Page Reporting](https://developers.redhat.com/articles/2024/03/13/save-memory-openshift-virtualization-using-free-page-reporting)
- [Memory management overview (guest-cooperative reclaim)](https://developers.redhat.com/articles/2026/10/15/red-hat-openshift-virtualization-memory-management-overview#guest-cooperative-memory-reclamation)

## KSM (kernel samepage merging)

**Kernel samepage merging (KSM)** is a host-side dedup path: the kernel scans for
identical VM memory pages and merges them to free RAM. Unlike FPR, it does not
need guest cooperation. This lab enables classic KSM on `HyperConverged`
`spec.virtualization.ksmConfiguration` (disabled by default; trusted workloads
only). Autopilot separately advertises opt-in **KSM zero pages only**
(`platform.kubevirt.io/enable-ksm-zero-only=true`, requiring
`ksmConfiguration` unconfigured) — see
[List features on the cluster](#list-features-on-the-cluster). Docs:
[Activating KSM](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/virtualization/nodes#virt-activating-ksm),
[KubeVirt KSM](https://kubevirt.io/user-guide/cluster_admin/ksm/).

### Before enable (baseline)

vlan615 (2026-10-26), before setting `ksmConfiguration`:

HCO has no usable KSM selector (`{}` or unset — nil `nodeLabelSelector` means
KSM on **no** nodes; only `nodeLabelSelector: {}` enables all nodes):

```bash
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.virtualization.ksmConfiguration}{"\n"}'
```

```text
{}
```

Workers report KSM not enabled:

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

### Enable via HCO

Enable CNV KSM activation on all nodes (`nodeLabelSelector: {}`). On CNV 4.22
the field is under `spec.virtualization` (not top-level `spec.ksmConfiguration`):

```bash
oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv --type=merge \
  -p '{"spec":{"virtualization":{"ksmConfiguration":{"nodeLabelSelector":{}}}}}'
```

Confirm HCO and the KubeVirt CR both show `{"nodeLabelSelector":{}}`:

```bash
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.virtualization.ksmConfiguration}{"\n"}'

oc get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.configuration.ksmConfiguration}{"\n"}'
```

### After enable

vlan615 (2026-10-26), after the patch above:

```bash
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.virtualization.ksmConfiguration}{"\n"}'
oc get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.configuration.ksmConfiguration}{"\n"}'
```

```text
{"nodeLabelSelector":{}}
{"nodeLabelSelector":{}}
```

Workers are labeled for KubeVirt-managed KSM:

```bash
oc get nodes -l node-role.kubernetes.io/worker -L kubevirt.io/ksm-enabled
```

```text
NAME               STATUS   ROLES    AGE   VERSION   KSM-ENABLED
d35-h26-000-r660   Ready    worker   13d   v1.35.8   true
d35-h27-000-r660   Ready    worker   13d   v1.35.8   true
d36-h02-000-r660   Ready    worker   13d   v1.35.8   true
d36-h03-000-r660   Ready    worker   13d   v1.35.8   true
d36-h04-000-r660   Ready    worker   13d   v1.35.8   true
d36-h07-000-r660   Ready    worker   13d   v1.35.8   true
d36-h08-000-r660   Ready    worker   13d   v1.35.8   true
d36-h20-000-r660   Ready    worker   13d   v1.35.8   true
d37-h14-000-r660   Ready    worker   13d   v1.35.8   true
```

`kubevirt.io/ksm-enabled=true` means the node is **configured** for CNV/KubeVirt
KSM (eligible for pressure-based activation), not that `ksmd` is running right
now ([KubeVirt PR #11306](https://github.com/kubevirt/kubevirt/pull/11306):
label reflects managed/configured, not the live `run` value). OpenShift docs
state CNV activates KSM **when nodes experience memory overload**
([Activating KSM](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/virtualization/nodes#virt-activating-ksm);
[4.15 release notes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.15/html/virtualization/release-notes)).
Upstream enables `ksmd` under pressure only
([PR #10477](https://github.com/kubevirt/kubevirt/pull/10477)).
With plenty of free RAM, host sysfs can still show idle:

```bash
oc debug node/d36-h07-000-r660 -- chroot /host bash -c \
  'echo run=$(cat /sys/kernel/mm/ksm/run); echo shared=$(cat /sys/kernel/mm/ksm/pages_shared); echo sharing=$(cat /sys/kernel/mm/ksm/pages_sharing)'
```

```text
run=0
shared=0
sharing=0
```

- Label `true` + HCO `nodeLabelSelector: {}` → enable succeeded (feature armed).
- `run=0` / `pages_*=0` → expected until the node is under memory pressure; then
  expect `run=1` and rising `pages_shared` / `pages_sharing`.
- Annotation `kubevirt.io/ksm-handler-managed` is set when virt-handler has
  actually flipped KSM on under overload (see same
  [Activating KSM](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/virtualization/nodes#virt-activating-ksm)
  label notes).

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

- [Red Hat OpenShift Virtualization memory management overview](https://developers.redhat.com/articles/2026/10/15/red-hat-openshift-virtualization-memory-management-overview#scheduler_memory_handling_and_reservations) — (2026-10-15)
- [Save memory with OpenShift Virtualization using Free Page Reporting](https://developers.redhat.com/articles/2024/03/13/save-memory-openshift-virtualization-using-free-page-reporting) — (2024-03-13)
- [Kernel free page reporting](https://docs.kernel.org/mm/free_page_reporting.html)
- [How to check VIRTIO feature bits inside Linux guests](http://blog.vmsplice.net/2020/05/how-to-check-virtio-feature-bits-inside.html)
- [Activating kernel samepage merging (KSM)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/virtualization/nodes#virt-activating-ksm) — OCP: activate on memory overload; `ksm-handler-managed` when CNV flips KSM on
- [OpenShift Virtualization 4.15 release notes (KSM)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.15/html/virtualization/release-notes) — activate KSM when a node is overloaded
- [KubeVirt KSM Management](https://kubevirt.io/user-guide/cluster_admin/ksm/)
- [KubeVirt PR #10477 — KSM according to memory pressure](https://github.com/kubevirt/kubevirt/pull/10477)
- [KubeVirt PR #11306 — `ksm-enabled` label = managed/configured, not live `run`](https://github.com/kubevirt/kubevirt/pull/11306)
- [Introducing virtualization platform autopilot](https://developers.redhat.com/articles/2026/05/07/introducing-virtualization-platform-autopilot) — (2026-05-07)
