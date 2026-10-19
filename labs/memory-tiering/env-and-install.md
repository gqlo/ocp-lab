# Memory tiering — env and install

**Last Updated:** 2026-10-19

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
  - [Worker SSH (bastion key)](#worker-ssh-bastion-key)
    - [`worker-ssh-key-mcp.yaml`](#worker-ssh-key-mcpyaml)
    - [Verify](#verify)
  - [Environment](#environment)
  - [CNV installation](#cnv-installation)
  - [LVMCluster (LVMS / SSD)](#lvmcluster-lvms--ssd)
    - [LVMCluster CR](#lvmcluster-cr)
    - [Verify](#verify-1)
  - [Setup swap](#setup-swap)
  - [Autopilot wiring](#autopilot-wiring)
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
| Autopilot | `virt-platform-autopilot` Ready; HCO annotation `platform.kubevirt.io/autopilot=descheduler-loadaware` (2026-10-19) |
| Descheduler | Operator **5.4.3**; `KubeDescheduler/cluster` Managed, profile `KubeVirtRelieveAndMigrate`, mode Automatic; workers have `psi=1` |

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

## Setup swap

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

## Autopilot wiring

Overview and enablement (OpenShift Virtualization 4.22 developer preview):

- [Introducing virtualization platform autopilot](https://developers.redhat.com/articles/2026/05/07/introducing-virtualization-platform-autopilot) (Red Hat Developer, 2026-05-07)

Opt in on the HyperConverged CR (`platform.kubevirt.io/autopilot` annotation). Feature flags include `swap-enable`, `descheduler-loadaware`, `prometheus-alerts`, and others; use `true` for all features, or a comma-separated subset. Dry-run via `virt-platform-autopilot` `/debug/render` is covered in the same article.

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

On vlan615 (2026-10-19) only **descheduler-loadaware** was enabled so far (swap / KSM / FPR still pending):

```bash
oc annotate hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  platform.kubevirt.io/autopilot=descheduler-loadaware --overwrite
```

Resulting HCO annotations:

```text
{"deployOVS":"false","platform.kubevirt.io/autopilot":"descheduler-loadaware"}
```

Autopilot then installs/reconciles the Kube Descheduler Operator and related objects (labeled `platform.kubevirt.io/managed-by: virt-platform-autopilot`). See [Descheduler (load-aware)](#descheduler-load-aware).

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
spec:
  kernelArguments:
  - psi=1
```

```text
Starting pod/d37-h14-000-r660-debug-... ...
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
