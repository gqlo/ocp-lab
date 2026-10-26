# CDI disk paths: DataSource clone vs HTTP import

**Last Updated:** 2026-10-23

How OpenShift Virtualization (CNV) / CDI populates VM disks, what you see on
the cluster for each path, and what we verified with vstorm on LVMS (TopoLVM)
vs the usual ODF snapshot flow.

Related: [pvc-vs-snapshot-clone.md](pvc-vs-snapshot-clone.md) (Ceph-side PVC vs
snapshot clone), [vstorm WFFC deadlock](../../../vstorm/docs/wffc-base-dv-deadlock.md)
(if both repos are checked out as siblings under the same parent).

## Who does what

| Component | Role |
| --- | --- |
| **virt-controller** | Materializes `dataVolumeTemplates` into DataVolumes; starts VMI when disk is ready |
| **CDI** (`cdi-deployment` in `openshift-cnv`) | Populates / clones PVCs for DataVolumes |
| **CSI / storage** (Ceph, TopoLVM, …) | Provisions volumes; may perform CSI clone or snapshot restore |
| **Importer / clone helper pods** | Only for some strategies (see below) |

CDI is involved for **PVC-backed** disks. It is **not** used for `--containerdisk`
(disk file lives in a container image).

## Path A — HTTP import (`source.http` / `--dv-url`)

```text
HTTP qcow URL
    │
    ▼  CDI import-controller + importer-prime-… pod
TransferScratch → /scratch/tmpimage  (often needs large scratch PVC)
    │
    ▼
target PVC (Block or FS)
```

**Characteristics**

- Downloads and converts the image **inside** the importer pod.
- Default CDI storage-workload memory is often **600Mi** — large qcow imports
  can OOM (`write /scratch/tmpimage: cannot allocate memory`, exit 137) and
  loop (pod killed → scratch recreated → progress resets).
- On **WaitForFirstConsumer** (LVMS), an intermediate “base” DV with no consumer
  can deadlock; see vstorm WFFC doc. Mitigation: annotate base DV with
  `cdi.kubevirt.io/storage.bind.immediate.requested=true`, or avoid this path.

**Pods you expect:** `importer-…` (and scratch PVC).

## Path B — DataSource / PVC clone (`sourceRef` → `source.pvc`)

Golden images live under `openshift-virtualization-os-images` (DataImportCron →
DataSource → PVC). A VM DV references the DataSource; CDI resolves it to a PVC
and **clones**.

```text
DataSource (e.g. rhel9) ──► existing PVC in openshift-virtualization-os-images
                                    │
                                    ▼  CDI clone (strategy from StorageProfile)
                         VM namespace target PVC
                                    │
                                    ▼
                              virt-launcher
```

**No HTTP pull** of the qcow in the VM batch. Content was imported earlier
(usually **registry** + `pullMethod: node` for boot sources).

### Clone strategies (`oc get storageprofile <sc> -o yaml`)

| Strategy | Where bytes move | Typical pods |
| --- | --- | --- |
| **csi-clone** / smart snapshot (common on **ODF**) | Inside storage | Often no host copy pods |
| **copy** (common on **LVMS** / TopoLVM) | Host-assisted | `*-source-pod` + `cdi-upload-tmp-pvc-…` |

Coordinator is still CDI (`clone-populator` / clone controllers). Import
controller skips these PVCs (no `storage.import.endpoint`).

### Verified lab run (2026-10-23, LVMS)

```bash
./vstorm --batch-id=dsverify2 --datasource=rhel9 --no-snapshot \
  --storage-class=lvms-lvm-d37-h14-000-r660-ssd-storage \
  --vms=1 --namespaces=1
```

Observed:

| Check | Result |
| --- | --- |
| DV source | `source.pvc` → `openshift-virtualization-os-images/rhel9-7005186c23b8` (not `http`) |
| Annotation | `cdi.kubevirt.io/cloneType: copy` |
| CDI logs | `clone-populator` phases `HostClone` → `Rebind` |
| Helper pods | `…-source-pod` + `cdi-upload-tmp-pvc-…` in **os-images** ns |
| Importer in VM ns | **None** |
| Outcome | DV `Succeeded` ~2m; VM `Running` |

Progress example: `CloneInProgress` 17% → 100%, then virt-launcher Running.

## Path C — Snapshot clone (typical ODF + vstorm default)

```text
source (DataSource or URL base) → base PVC → VolumeSnapshot → per-VM DV from snapshot
```

On ODF this is usually cheap (Ceph snapshot/restore). Snapshots are often
**disabled** automatically on WFFC/LVMS; use Path B (`--no-snapshot --datasource=…`)
instead.

## Boot images not Ready (`DataSource` NoSource)

DataImportCron DVs often omit `storageClassName` / `accessModes`. CDI needs a
**default** StorageClass to pick a StorageProfile. Error:

```text
PVC spec is missing accessMode and no storageClass to choose profile
ErrClaimNotValid
```

On LVMS, patching the StorageClass annotation is often **reverted** by the LVM
operator. Set default on the **LVMCluster** device class instead:

```bash
oc patch lvmcluster ssd-lvmcluster -n openshift-lvm-storage --type=json -p '[
  {"op":"add","path":"/spec/storage/deviceClasses/0/default","value":true}
]'

oc get sc <lvms-sc> -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}'
# must stay true

# recreate stuck boot DVs if needed
oc delete dv rhel9-… -n openshift-virtualization-os-images
```

Then:

```bash
oc get datasource -n openshift-virtualization-os-images \
  -o custom-columns=NAME:.metadata.name,READY:.status.conditions[0].status,PVC:.status.source.pvc.name
```

## Quick decision guide

| Goal | Prefer |
| --- | --- |
| ODF lab, many VMs | Snapshot path (Path C) or DataSource + snap |
| LVMS / WFFC | `--no-snapshot --datasource=NAME` (Path B) |
| Custom qcow URL | `--dv-url` (Path A) + raise CDI importer memory; WFFC needs bind-immediate on base |
| Avoid CDI entirely | `--containerdisk=…` |

Raise CDI importer limits via HyperConverged when stuck on Path A OOM:

```bash
oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv --type=merge -p '{
  "spec": {
    "storage": {
      "workloadResourceRequirements": {
        "limits": {"cpu":"2","memory":"4Gi"},
        "requests": {"cpu":"100m","memory":"512Mi"}
      }
    }
  }
}'
```

## Useful commands

```bash
# Strategy for a StorageClass
oc get storageprofile <sc> -o jsonpath='{.status.cloneStrategy}{"\n"}'

# Is this DV an import or a clone?
oc get dv <name> -n <ns> -o yaml | grep -E 'http:|pvc:|snapshot:|cloneType|phase|progress'

# CDI vs virt for a batch
oc logs -n openshift-cnv deploy/cdi-deployment --since=10m | grep -E 'clone-populator|HostClone|import-controller'
oc logs -n openshift-cnv deploy/virt-controller --since=10m | grep <vm-name>

# Helper pods during HostClone
oc get pods -A | grep -E 'source-pod|cdi-upload-tmp|importer'
```
