# openshift-sre-notes

OpenShift SRE field notes: troubleshooting notes, runbooks, and hands-on labs for cluster ops (networking, storage/ODF, virtualization/CNV, monitoring, scale).

Use **[INDEX.md](INDEX.md)** to look up notes by symptom. AI agents: see **[AGENTS.md](AGENTS.md)**.

## Layout

```text
openshift-sre-notes/
├── INDEX.md              # symptom → note map
├── AGENTS.md             # how agents should search this repo
├── troubleshooting/      # debugging notes (symptoms → root cause → recovery)
│   ├── networking/
│   ├── storage/
│   └── virtualization/
├── runbooks/             # repeatable procedures (checks → steps → verify)
│   ├── cluster-admin/
│   └── virtualization/
├── labs/                 # hands-on labs and durable how-tos
│   ├── networking/
│   ├── storage/
│   ├── monitoring/
│   ├── ebpf/
│   ├── scale/
│   └── os-install/
└── resources/            # supporting assets
    ├── blogs/
    ├── scripts/
    └── templates/
```

## Quick links

| Type | Entry |
| ---- | ----- |
| Lookup | [INDEX.md](INDEX.md) |
| Troubleshooting | [troubleshooting/](troubleshooting/) |
| Runbooks | [runbooks/](runbooks/) |
| Labs | [labs/](labs/) |
| Resources | [resources/](resources/) |

## Content types

| Folder | Put here when… |
| ------ | -------------- |
| `troubleshooting/` | Debugging writeup: symptoms, evidence, root cause, recovery |
| `runbooks/` | Repeatable procedure with ordered steps and verify |
| `labs/` | Hands-on labs and durable how-tos (not a single outage) |
| `resources/` | Blogs, scripts, YAML templates (supporting assets) |

Domains stay stable: `networking`, `storage`, `virtualization`, `cluster-admin`, `monitoring`, `scale`.
