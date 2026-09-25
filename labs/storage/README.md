# Storage labs (Ceph / ODF / NetApp)

**Last Updated:** 2026-09-24

## Catalog

| Doc | Topic |
| --- | ----- |
| [pvc-vs-snapshot-clone.md](pvc-vs-snapshot-clone.md) | PVC clone vs snapshot clone behavior inside Ceph (CNV relevance) |
| [netapp/netapp-setup-notes.md](netapp/netapp-setup-notes.md) | Trident NFS SVM setup notes + NNCP / backend manifests |

## Related troubleshooting

| Doc | Topic |
| --- | ----- |
| [ODF PDBs vs MCP drain](../../troubleshooting/storage/odf-pdb-vs-mcp-drain.md) | Rook/ODF PDBs vs MCP `maxUnavailable`; drain stuck on OSD eviction |
| [OSD FDs vs CRI-O `nofile`](../../troubleshooting/storage/osd-crio-nofile-fd-exhaustion.md) | ~222 OSDs, 1400+ FDs/OSD (peer sockets); default `1024:2048` too low |
| [UDN → OSD flapping & Rook 24h sleep](../../troubleshooting/networking/udn-odf-osd-flapping/udn-odf-osd-flapping.md) | UDN network outage: pods Running but daemons asleep; batched recovery |

## Related

- [High-scale ODF / drain notes](../scale/high-scale-config-notes.md)
- [Rook managed disruption budgets (design)](https://github.com/rook/rook/blob/master/design/ceph/ceph-managed-disruptionbudgets.md)
