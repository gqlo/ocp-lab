# Agent guidance — openshift-sre-notes

How to use this repository when helping with OpenShift / ODF / CNV troubleshooting or ops.

## Search order

1. Read **[INDEX.md](INDEX.md)** and match user symptoms, error strings, or products.
2. Search under **`troubleshooting/`** for similar debugging notes (Lesson, Symptoms, Root cause, Recovery).
3. Use **`runbooks/`** when the user wants a repeatable procedure (node remove, upgrade, VM teardown).
4. Use **`labs/`** for hands-on labs and how-tos (tracing, eBPF, scale config, monitoring).
5. Point at **`resources/templates/`** and **`resources/scripts/`** only as supporting assets linked from a note.

## How to answer

- Prefer the note’s **Lesson (short)** and **Recovery** / procedure steps.
- **Cite file paths** (and section headings when useful) so the user can open the source.
- If several notes match, list them briefly and lead with the best symptom match.
- Do not invent recovery steps that contradict a linked note; if unsure, say so and cite the closest note.

## Domains

| Domain | Typical products / surfaces |
| ------ | --------------------------- |
| networking | OVN-Kubernetes, UDN, DNS, Multus, MetalLB, OVS |
| storage | ODF, Rook, Ceph, LSO/LVM, NetApp Trident |
| virtualization | OpenShift Virtualization, KubeVirt, virtctl |
| cluster-admin | nodes, MCP, Machine API, upgrades |
| monitoring | Prometheus, COO, metrics exporters |
| scale | large-node / large-VM fleet config |

## Adding notes (for humans)

- One primary lesson per note.
- Troubleshooting folders when there are images/logs; otherwise a single markdown file is fine.
- Link related notes and `resources/` assets — do not duplicate YAML into troubleshooting notes.
- Update **INDEX.md** when adding a note others should find by symptom.
