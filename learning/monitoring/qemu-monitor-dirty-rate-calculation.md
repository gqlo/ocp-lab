# QEMU Monitor Dirty Rate Calculation

How guest memory dirty rate is measured via the QEMU monitor (QMP), how `virsh qemu-monitor-command` fits in, and how that relates to KubeVirt Prometheus metrics.

**Last Updated:** 2026-08-10

## What “dirty rate” means

**Dirty rate** is how fast the guest is rewriting RAM, in **MiB/s** (or bytes/s after conversion):

\[
\text{dirty rate} \approx \frac{\text{(pages written at least once in window } T) \times \text{page size}}{T}
\]

Important:

- A page is dirty if it was **written** after tracking was cleared for that window.
- Writing the **same** page many times in one window still counts as **one** dirty page.
- **Used memory** (RSS / guest used) is not the same as dirty rate. A buffer can stay resident while dirty rate drops to ~0 if nothing rewrites it.

---

## End-to-end path (KubeVirt / virt-launcher)

```text
Guest workload writes RAM (e.g. dirty-mem-pages)
        │
        ▼
KVM marks guest pages dirty (dirty log / bitmap)
        │
        ▼
QEMU calc-dirty-rate / query-dirty-rate   ← real calculation lives here
        ▲
        │  QMP JSON over monitor socket
        │
virsh qemu-monitor-command DOMAIN '{...}'  ← libvirt only forwards
        ▲
        │
kubectl/oc exec into virt-launcher (compute)
```

**Libvirt does not compute dirty rate.**  
`virsh qemu-monitor-command` is a passthrough to QEMU’s QMP monitor.

| Layer | Role | Upstream |
| ----- | ---- | -------- |
| Guest process | Causes writes | e.g. vstorm `workload/dirty-mem-pages.c` |
| KVM | Sets dirty bits on write | Linux KVM |
| QEMU | Runs measurement, returns MiB/s | [qemu/qemu](https://github.com/qemu/qemu) (`migration/dirtyrate.c`) |
| libvirt / virsh | Forwards QMP JSON | [libvirt/libvirt](https://gitlab.com/libvirt/libvirt) |
| KubeVirt metric | Separate collector (page-sampling via libvirt API) | [kubevirt/kubevirt](https://github.com/kubevirt/kubevirt) |

---

## How `virsh qemu-monitor-command` works

Example (same idea as vstorm’s `monitoring/scripts/kubevirt-dirty-rate.sh`):

```bash
virsh qemu-monitor-command "${DOMAIN}" \
  '{"execute":"calc-dirty-rate","arguments":{"calc-time":1,"mode":"dirty-bitmap"}}'

# wait ≥ calc-time, then:
virsh qemu-monitor-command "${DOMAIN}" \
  '{"execute":"query-dirty-rate"}'
# → .return["dirty-rate"]  (MiB/s when status is "measured")
```

Libvirt path:

1. `virsh` → `virDomainQemuMonitorCommand()` ([`src/libvirt-qemu.c`](https://gitlab.com/libvirt/libvirt/-/blob/master/src/libvirt-qemu.c))
2. QEMU driver sends the string on the domain’s monitor (`qemuMonitorSend` in [`src/qemu/qemu_monitor.c`](https://gitlab.com/libvirt/libvirt/-/blob/master/src/qemu/qemu_monitor.c))
3. QEMU replies with JSON; virsh prints it

Libvirt never interprets `calc-dirty-rate`; it only relays.

On OpenShift / KubeVirt, run that **inside** the VMI’s `virt-launcher` pod (`compute` container), where `virsh` talks to that VM’s QEMU.

---

## QEMU: `calc-dirty-rate` and `query-dirty-rate`

QMP API: [`qapi/migration.json`](https://github.com/qemu/qemu/blob/master/qapi/migration.json)  
Implementation: [`migration/dirtyrate.c`](https://github.com/qemu/qemu/blob/master/migration/dirtyrate.c)

### Commands

| QMP | Purpose |
| --- | ------- |
| `calc-dirty-rate` | Start a measurement for `calc-time` (async thread) |
| `query-dirty-rate` | Read status / result of the latest run |

`calc-dirty-rate` returns immediately after starting the thread. Results appear later via `query-dirty-rate` when `status` is `measured`.

### Modes

| Mode | Mechanism | Notes |
| ---- | --------- | ----- |
| **`dirty-bitmap`** | Enable KVM dirty logging, clear bitmap, wait `T`, sync and count dirty pages | What the vstorm script uses; needs dirty-ring **not** enabled |
| **`page-sampling`** | Hash a random sample of pages at start and end of `T`; changed hashes ≈ dirty | Default if `mode` omitted; cheaper estimate |
| **`dirty-ring`** | Per-vCPU dirty ring counters over `T` | Needs KVM dirty-ring |

---

## Dirty-bitmap mode (step by step)

This is what your monitor script uses (`mode: dirty-bitmap`).

```text
1. memory_global_dirty_log_start()     # turn on KVM write tracking
2. sync + clear / reset protect        # clean slate (skip noisy first sync)
3. start_pages = total_dirty_pages
4. sleep(calc-time)                    # guest writes → KVM sets bits
5. memory_global_dirty_log_sync()      # pull bitmap from KVM, stop logging
6. end_pages = total_dirty_pages
7. dirty_rate_MiB_s =
     pages_to_MiB(end_pages - start_pages) * 1000 / duration_ms
```

Roughly from QEMU:

```c
increased = end_pages - start_pages;
rate_MiB_s = qemu_target_pages_to_MiB(increased * 1000) / calc_time_ms;
```

So for a 1s window: if ~819200 distinct 4KiB pages were written → ~3200 MiB → ~3200 MiB/s.

---

## Page-sampling mode (brief)

Used by default QMP / similar to KubeVirt’s libvirt `StartDirtyRateCalc(..., PAGE_SAMPLING)` path:

1. Pick random pages (~512 per GiB of guest RAM by default).
2. Hash each sample at `t=0`.
3. Wait `calc-time`.
4. Hash again; count samples whose hash changed.
5. Extrapolate to whole RAM → estimated MiB/s.

Faster / lighter than a full bitmap; noisier.

---

## How a guest write becomes a dirty bit

The guest program does **not** read the dirty bitmap. It only stores to memory:

```c
mem[page_idx * page] = (char)i;   // one store → that page can be marked dirty
```

Hypervisor side:

```text
Guest store to GPA
  → KVM write-tracking (fault or hardware dirty log, e.g. PML)
  → dirty bitmap bit for that page = 1
  → QEMU counts bits (or samples) after window T
```

---

## KubeVirt Prometheus metric vs QMP script

| Source | How measured | Unit exposed |
| ------ | ------------ | ------------ |
| `virsh` + `calc-dirty-rate` / `query-dirty-rate` (`dirty-bitmap`) | Full dirty log over `T` | MiB/s in QMP |
| `kubevirt_vmi_dirty_rate_bytes_per_second` | virt-handler → virt-launcher → libvirt `StartDirtyRateCalc` with **page-sampling** | bytes/s (`MB/s × 1024²`) |

Same idea (writes over a window), different mode → numbers can differ. During live migration, migration job stats use their own dirty tracking (`DomainJobInfo`), separate from the periodic Prometheus collector (which skips migrating VMIs).

---

## Practical lab commands

### From a virt-launcher pod

```bash
NS=my-ns
POD=$(oc get pods -n "$NS" -l kubevirt.io=virt-launcher --no-headers | awk '{print $1; exit}')
DOMAIN=$(oc exec -n "$NS" "$POD" -c compute -- virsh list --name | head -1)

oc exec -n "$NS" "$POD" -c compute -- \
  virsh qemu-monitor-command "$DOMAIN" \
  '{"execute":"calc-dirty-rate","arguments":{"calc-time":1,"mode":"dirty-bitmap"}}'

sleep 2

oc exec -n "$NS" "$POD" -c compute -- \
  virsh qemu-monitor-command "$DOMAIN" \
  '{"execute":"query-dirty-rate"}' | jq .
```

Or use the wrapper: [vstorm `monitoring/scripts/kubevirt-dirty-rate.sh`](https://github.com/gqlo/vstorm/blob/main/monitoring/scripts/kubevirt-dirty-rate.sh).

### Generate steady dirty traffic in the guest

vstorm cloud-init workload compiles and runs `dirty-mem-pages`:

- Buffer size = `DIRTY_RATE_FRACTION × guest_RAM`
- Target: rewrite ~that many bytes of **pages** every second (one byte per page is enough)

Example expectation on an 8 GiB VMI with fraction `0.4`: ~3.2 GiB/s dirty rate order-of-magnitude while the service is active.

`stress-ng --vm` allocates/touches memory but is **not** a calibrated dirty-rate generator (bursty, often remaps, idle cycles, some methods only read). Prefer `dirty-mem-pages` when validating dirty rate.

---

## Mental checklist

| Question | Answer |
| -------- | ------ |
| Who calculates dirty rate for the virsh QMP path? | **QEMU** (`migration/dirtyrate.c`) |
| What does libvirt do? | Forward QMP only |
| Who marks pages dirty? | **KVM**, on guest writes |
| Does the guest C program read the bitmap? | **No** — it only writes |
| Dirty rate vs memory used? | Orthogonal: used can be high with dirty rate ≈ 0 |

---

## References

- QEMU QMP: [calc-dirty-rate](https://github.com/qemu/qemu/blob/master/qapi/migration.json)
- QEMU impl: [migration/dirtyrate.c](https://github.com/qemu/qemu/blob/master/migration/dirtyrate.c)
- libvirt passthrough: [virDomainQemuMonitorCommand](https://gitlab.com/libvirt/libvirt/-/blob/master/src/libvirt-qemu.c)
- KubeVirt metric: `kubevirt_vmi_dirty_rate_bytes_per_second` (virt-handler domain dirty-rate collector)
- Related lab notes: [KubeVirt metrics catalog](https://kubevirt.io/monitoring/metrics.html)
