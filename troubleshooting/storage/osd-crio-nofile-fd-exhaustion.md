# ODF OSD file descriptors vs CRI-O `nofile` at scale

**Last Updated:** 2026-09-25

Lab notes from a large ODF cluster (~222 OSDs, 1 OSD per worker) where each OSD
process opened well over a thousand file descriptors — mostly TCP sockets to peer
OSDs — and hit CRI-O’s default `nofile` limit.

**OCP:** 4.22.0 (Kubernetes v1.35.5)

## Catalog

- [Lesson (short)](#lesson-short)
- [Environment](#environment)
- [Symptoms](#symptoms)
- [Root cause](#root-cause)
- [Evidence](#evidence)
  - [Per-OSD FD count](#per-osd-fd-count)
  - [Sockets dominate the FD table](#sockets-dominate-the-fd-table)
  - [Peer TCP connections](#peer-tcp-connections)
  - [CRI-O default `nofile`](#cri-o-default-nofile)
- [Why this shows up at ~200+ OSDs](#why-this-shows-up-at-200-osds)
- [Workaround (unsupported)](#workaround-unsupported)
- [Supportability](#supportability)
- [Related](#related)
- [Refs](#refs)

---

## Lesson (short)

At large OSD count, each Ceph OSD keeps **several TCP connections to every other
OSD** (replication, recovery, peering). FD usage is dominated by those sockets and
routinely exceeds **CRI-O’s default `nofile=1024:2048`**.

That limit is fine for typical app pods; it is **not** sized for dense Ceph OSD
meshes. When the process hits the soft/hard FD cap, OSD I/O and peering fail and
the storage cluster destabilizes.

Raising `nofile` via MachineConfig / CRI-O config was an effective **lab
workaround**, but Red Hat documents that path as **unsupported**. Prefer tracking
supported guidance / product fixes for scale; treat MC overrides as temporary.

## Environment

| Item | Value |
|------|--------|
| Cluster | Large bare-metal ODF fleet |
| OSDs | ~222 (1 OSD per worker in this lab) |
| Observed FD count (example OSD PID) | **1469** open FDs |
| Default CRI-O limit | `nofile=1024:2048` (commented example in `crio.conf`) |
| OCP | 4.22.0 |

## Symptoms

- OSD pods / daemons fail or become unstable as OSD count grows toward ~200+
- Storage cluster destabilizes under normal peering / replication load
- Inside the OSD container (or host namespace for the OSD PID),
  `ls /proc/<pid>/fd | wc -l` reports **>1024** (often ~1400–1500+)
- FD listing is mostly `socket:[…]` entries
- `ss` / `netstat` shows many `ESTAB` connections on OSD ports (`6800`–`680x`)
  between this node and peer OSD IPs

## Root cause

Ceph OSDs form a **full mesh of messenger connections**. Each OSD typically
maintains on the order of **3–5 active TCP connections per peer OSD** for
replication, recovery, and peering.

Rough scale (order of magnitude):

```text
peers ≈ 221
connections/peer ≈ 3–5
→ hundreds to ~1000+ peer sockets per OSD
+ local disks, pipes, logs, admin sockets, …
→ total FDs often > 1024 / approaching 2048
```

CRI-O’s default container `nofile` soft:hard of **1024:2048** is the box those
sockets live in. Exhausting it is a **scale × mesh** problem, not a random leak
in this lab.

## Evidence

### Per-OSD FD count

```bash
# Inside the OSD pod / debug shell for the OSD process
ls /proc/10366/fd | wc -l
# 1469
```

### Sockets dominate the FD table

```text
ls -l /proc/10366/fd
…
lrwx------. 1 167 167 64 … 100  -> socket:[135599]
lrwx------. 1 167 167 64 … 1000 -> socket:[24318688]
lrwx------. 1 167 167 64 … 1002 -> socket:[44380192]
…
```

Stdin/stdout pipes and a few non-socket FDs exist; the bulk of the table is
network sockets.

### Peer TCP connections

Representative established sessions (OSD ports `6800` / `6802` / `6804` / `6806`
to many peer node IPs):

```text
ESTAB  0  0  10.175.16.14:6806   10.158.16.12:52612
ESTAB  0  0  10.175.16.14:44914  10.146.0.13:6802
ESTAB  0  0  10.175.16.14:6800   10.150.0.2:57414
ESTAB  0  0  10.175.16.14:35188  10.175.0.15:6802
ESTAB  0  0  10.175.16.14:6800   10.162.16.2:51080
ESTAB  0  0  10.175.16.14:32906  10.148.0.14:6806
ESTAB  0  0  10.175.16.14:6804   10.178.0.12:51994
ESTAB  0  0  10.175.16.14:6806   10.157.16.8:58694
ESTAB  0  0  10.175.16.14:6800   10.177.0.2:40692
…
```

### CRI-O default `nofile`

```bash
grep -r nofile /etc/crio/
# /etc/crio/crio.conf:# "nofile=1024:2048"
```

## Why this shows up at ~200+ OSDs

| Workload | Typical FDs | Hit 1024/2048? |
|----------|-------------|----------------|
| Typical app container | tens–low hundreds | Rarely |
| Ceph OSD @ small cluster | moderate mesh | Often OK |
| Ceph OSD @ ~222 OSDs | 3–5 conns × ~221 peers + local FDs | **Yes** |

Per-OSD connection and FD usage is **far higher than typical container
workloads**. Defaults that work for OpenShift app pods are undersized for this
OSD mesh.

## Workaround (unsupported)

Lab workaround: apply a **MachineConfig** that raises the container / CRI-O
`nofile` (and related limits) above the observed peak (with headroom beyond
~1500+ FDs per OSD).

That stopped OSD failures caused by FD exhaustion in this fleet, but it is
**not a supported** way to run OpenShift. See Red Hat solution
[6974793](https://access.redhat.com/solutions/6974793).

Do **not** treat MC/`crio.conf` `nofile` overrides as the long-term supported
fix path without confirming current product guidance for your OCP/ODF version.

## Supportability

| Approach | Status (per RH KCS 6974793 and this lab) |
|----------|------------------------------------------|
| Default CRI-O `nofile=1024:2048` | Supported default; insufficient at this OSD scale |
| MachineConfig / manual CRI-O `nofile` override | **Unsupported** workaround used in lab |
| Product / support-backed limit guidance | Prefer over MC hacks for production |

When opening a case, include: OSD count, `ls /proc/<pid>/fd | wc -l`, sample
`ls -l /proc/<pid>/fd` (socket-heavy), `ss` peer sample, OCP/ODF versions, and
that defaults are `1024:2048`.

## Related

- [High-scale ODF / cluster config notes](../../labs/scale/high-scale-config-notes.md)
- [ODF / Rook PDBs vs MCP drain](odf-pdb-vs-mcp-drain.md) — different failure mode, same fleet size
- [UDN → OSD flapping & Rook 24h sleep](../networking/udn-odf-osd-flapping/udn-odf-osd-flapping.md)

## Refs

- [Red Hat Solution 6974793 — changing CRI-O `nofile` via MachineConfig](https://access.redhat.com/solutions/6974793) (unsupported)
- Ceph OSD messenger / peering uses multiple connections per peer (replication, recovery, peering)
