# Auto-converge, pre-copy, and post-copy

Differences between the three live-migration strategies in KubeVirt/CNV, with **source evidence**. Also covers `completionTimeoutPerGiB` (what the GiB is, and why lowering it matters for post-copy).

**Last Updated:** 2026-11-04  
**Source tree:** `~/work/kubevirt/`

## Catalog

**Table of Contents**

- [Auto-converge, pre-copy, and post-copy](#auto-converge-pre-copy-and-post-copy)
  - [Catalog](#catalog)
  - [One-line comparison](#one-line-comparison)
  - [Mental model: only one guest executes](#mental-model-only-one-guest-executes)
  - [Pre-copy](#pre-copy)
  - [Auto-converge](#auto-converge)
  - [Post-copy](#post-copy)
  - [Side-by-side](#side-by-side)
  - [`completionTimeoutPerGiB`](#completiontimeoutpergib)
  - [Defaults and how they combine](#defaults-and-how-they-combine)
  - [Related](#related)

---

## One-line comparison

| Strategy | What it does | Guest impact | Risk if network dies mid-migration |
| --- | --- | --- | --- |
| **Pre-copy** (default mode) | Copy dirty memory while guest runs on **source**; switch when remaining state is small | Low during bulk transfer | Usually recoverable on source |
| **Auto-converge** (option on pre-copy) | Throttle guest **vCPUs** so dirty rate drops and pre-copy can finish | Guest slows (up to near-paused) | Same as pre-copy (safer) |
| **Post-copy** (optional later switch) | Move execution to **destination** early; pull remaining pages on fault | Possible page-fault latency on dest | Often **fatal** to the VM |

Auto-converge and post-copy are **not** alternate start modes in KubeVirt: migration **always starts in pre-copy**. Auto-converge is a pre-copy helper flag; post-copy is a later switch when the completion timeout fires (if allowed).

---

## Mental model: only one guest executes

Two virt-launcher pods exist (source + target), but only one side runs guest vCPUs at a time. The destination receives memory into a paused/incoming QEMU — it is **not** a second live twin serving traffic.

| Phase | Source | Destination |
| --- | --- | --- |
| Pre-copy bulk | Guest **running** | Paused / receiving pages |
| Pre-copy final switchover | Brief pause → done | Resume guest; migration complete |
| Post-copy after switch | Paused / ghost; may serve residual pages | Guest **running**; fault in missing pages |

### Evidence

`kubevirt/docs/probes.md`:

```text
Pre-copy phase  — guest paused on *target*, still running on *source*
Post-copy phase — guest paused on *source*, running on *target*
```

`kubevirt/pkg/virt-launcher/virtwrap/manager_test.go`:

```text
Pre-copy:  source VM still running (probe succeeds);
           target VM paused receiving memory pages (probe fails → suppress)
Post-copy: target VM now running;
           source handed off / ghost-paused (probe fails → suppress)
```

Target prep + “no domain yet” is expected:

```go
// manager.go — isGuestAgentUnavailableError
// ERR_NO_DOMAIN: domain not yet present on the target before pages start
// flowing (prepareMigrationTarget has run but migration has not begun).
```

Source initiates live peer2peer migration:

```go
// live-migration-source.go
migrateFlags := libvirt.MIGRATE_LIVE | libvirt.MIGRATE_PEER2PEER | libvirt.MIGRATE_PERSIST_DEST
...
err = dom.MigrateToURI3(dstURI, params, migrateFlags)
```

Incoming migration on dest runs **before** the VM starts there (`docs/devel/migration-premigration-hooks.md`).

---

## Pre-copy

Default migration **mode**. Guest stays on source while RAM is copied in rounds. Guest keeps dirtying pages → those are recopied until remaining dirty state is small enough for a short pause + final handoff.

```go
// live-migration-source.go — startMigration
inProgress, err := l.initializeMigrationMetadata(vmi, v1.MigrationPreCopy)
```

Mode enum (`api/core/v1/types.go`): `MigrationPreCopy`, `MigrationPostCopy`, `MigrationPaused`.

If pre-copy never converges (dirty rate ≥ transfer rate), migration stalls until timeout → abort, pause, or post-copy depending on config.

---

## Auto-converge

Still **pre-copy**. When enabled, QEMU/libvirt **CPU-throttles** the guest so it dirties memory more slowly, forcing pre-copy to converge.

KubeVirt API (`types.go`):

```go
// AllowAutoConverge allows the platform to compromise performance/availability
// of VMIs to guarantee successful VMI live migrations. Defaults to false
AllowAutoConverge *bool `json:"allowAutoConverge,omitempty"`
```

Flag wiring:

```go
// live-migration-source.go — generateMigrationFlags
if options.AllowAutoConverge {
    migrateFlags |= libvirt.MIGRATE_AUTO_CONVERGE
}
```

Default off:

```go
// virt-config.go
MigrationAllowAutoConverge bool = false
```

### What QEMU does (upstream behavior)

From [QEMU AutoconvergeLiveMigration](https://wiki.qemu.org/Features/AutoconvergeLiveMigration):

- If migration isn’t converging, start throttling guest CPUs (default initial **20%**).
- Periodically bump throttle (default **+10%**) until converge or ~**99%** throttled.
- Assumption: slower CPUs → lower memory dirty rate. Some write-heavy workloads don’t follow that; auto-converge may not help them.

Guest stays on the **source** the whole time (unlike post-copy). Cost is **performance**, not “split brain” risk.

---

## Post-copy

Optional. Migration still **starts** pre-copy; if `allowPostCopy` is true, hitting `completionTimeoutPerGiB` calls `MigrateStartPostCopy` and moves execution to the destination while residual pages remain on the source.

API (`types.go`):

```go
// AllowPostCopy ... Defaults to false
// If set to true, migrations will still start in pre-copy, but switch to
// post-copy when CompletionTimeoutPerGiB triggers.
```

Capability at start (not “start in post-copy”):

```go
if options.AllowPostCopy {
    migrateFlags |= libvirt.MIGRATE_POSTCOPY
}
```

Actual switch:

```go
// live-migration-source.go
logger.Info("completion timeout reached: starting post-copy mode to force convergence")
err := dom.MigrateStartPostCopy(0)
m.l.updateVMIMigrationMode(v1.MigrationPostCopy)
```

Why aborting during post-copy is dangerous:

```go
// post copy ... results in the target pod hosting the active workload while
// the migration completes.
// If we were to abort ... while in post copy, then it would result in that
// active state being lost.
```

Default off: `MigrationAllowPostCopy = false` (`virt-config.go`).

---

## Side-by-side

| | Pre-copy | Auto-converge | Post-copy |
| --- | --- | --- | --- |
| Role | Base mode | Helper **inside** pre-copy | Later **mode switch** |
| Where guest runs (bulk) | Source | Source | Destination (after switch) |
| How convergence is forced | Wait for dirty rate to drop | Throttle vCPUs → lower dirty rate | Run on dest; page-fault remaining RAM |
| Guest perf during migration | Normal | Degraded (increasing throttle) | Possible fault latency after switch |
| Failure mid-migration | Usually safe on source | Usually safe on source | Often VM-fatal |
| KubeVirt knob | (always) | `allowAutoConverge` | `allowPostCopy` |
| Libvirt flag | `MIGRATE_LIVE` … | `MIGRATE_AUTO_CONVERGE` | `MIGRATE_POSTCOPY` (+ later `MigrateStartPostCopy`) |

They can be combined: pre-copy + auto-converge, and still switch to post-copy on timeout if both are allowed (see e2e: “compression, autoconverge, and postcopy combined” in `tests/migration/migration.go`).

---

## `completionTimeoutPerGiB`

Seconds **per GiB** of migration data size. Timeout:

```text
acceptableCompletionTime = completionTimeoutPerGiB × getVMIMigrationDataSize(...)
```

`getVMIMigrationDataSize` (`manager.go`): guest **RAM** (+ ephemeral disks if `BlockMigration`, + migrated volumes). So primarily **memory**; disks only when they migrate too.

HyperConverged CRD: *“size of the guest (both RAM and migrated disks, if any)”*.

### Why 800 → 20 helps post-copy

> `800` here is **this cluster's prior configured value**, not an upstream default — the
> KubeVirt default is `150` and HyperConverged often ships `20` (see
> [Defaults and how they combine](#defaults-and-how-they-combine) below). The point is the
> direction: a large value to a small one.

Does not make post-copy “better.” It **ends the pre-copy wait sooner** so `MigrateStartPostCopy` can fire (when `allowPostCopy` is true). Without post-copy enabled, a lower value only aborts/pauses sooner.

Example 6 GiB RAM guest:

| `completionTimeoutPerGiB` | Pre-copy budget |
| --- | --- |
| 800 (prior config) | ~4800 s ≈ 1h20m |
| 20 | ~120 s ≈ 2 min |

---

## Defaults and how they combine

| Setting | Default |
| --- | --- |
| Migration mode at start | Always `PreCopy` |
| `allowAutoConverge` | `false` |
| `allowPostCopy` | `false` |
| `completionTimeoutPerGiB` | `150` in KubeVirt defaults; HyperConverged often ships `20` |

Typical outcomes when pre-copy stalls:

1. Neither helper → abort (or pause if workload disruption / VFIO paths apply).
2. Auto-converge only → stay on source, throttle until converge or timeout.
3. Post-copy allowed → after completion timeout, switch execution to dest.
4. Both → throttle during pre-copy; if still not done by timeout, post-copy switch.

---

## Related

- [QEMU dirty-rate](../monitoring/qemu-monitor-dirty-rate-calculation.md) — why busy guests struggle to converge
- KubeVirt: `pkg/virt-launcher/virtwrap/live-migration-source.go`, `live-migration-target.go`, `manager.go`
- Docs: `kubevirt/docs/probes.md`, `docs/devel/migration-premigration-hooks.md`
- QEMU: [AutoconvergeLiveMigration](https://wiki.qemu.org/Features/AutoconvergeLiveMigration)
