# Ceph / ODF learning notes

**Last Updated:** 2026-08-25

## Catalog

| Doc | Topic |
| --- | ----- |
| [odf-pdb-vs-mcp-drain.md](odf-pdb-vs-mcp-drain.md) | Rook/ODF PDBs vs MCP `maxUnavailable`: Pending trap, why 40 hurts; lab PDB bumps (OSD 15 / mon 3 / mgr 2) |
| [pvc-vs-snapshot-clone.md](pvc-vs-snapshot-clone.md) | PVC clone vs snapshot clone behavior inside Ceph (CNV relevance) |
| [UDN → OSD flapping & Rook 24h sleep](../networking/udn-odf-osd-flapping/udn-odf-osd-flapping.md) | UDN network outage: pods Running but daemons asleep; batched recovery |

## Related

- [High-scale ODF / drain notes](../ocp-admin/high-scale-config-notes.md)
- [Rook managed disruption budgets (design)](https://github.com/rook/rook/blob/master/design/ceph/ceph-managed-disruptionbudgets.md)
