# eBPF container image lab

Lab tooling for eBPF container images on OpenShift — build, push, and run debug toolboxes in pods.

| Image | Built from | Use for |
| ----- | ---------- | ------- |
| **`quay.io/rh_ee_lguoqing/toolbox:latest`** | [`Dockerfile`](Dockerfile) | `oc debug` into pods — `tcpdump`, `bpftrace`, `bcc-tools`, shell utilities |
| **`quay.io/rh_ee_lguoqing/ebpf_<version>`** | [`build-ebpf.sh`](build-ebpf.sh) | Privileged pods needing **kernel headers matched to a worker node** (e.g. [`ddpod.yaml`](../../templates/cnv/ddpod.yaml)) |

**Why not `dnf install` on the node or pod?** Workload images are minimal, RHCOS nodes are immutable, and `oc debug` containers are ephemeral. Pre-build tools into an image and push to Quay. For **BCC/bpftrace**, kernel headers must match the worker kernel — that is what the kernel-matched UBI image is for.

---

## 1. Toolbox image — build and run

Most common path: attach a debug shell to a pod (CoreDNS, app pod, etc.).

### Build

```bash
cd ocp-lab/learning/ebpf
podman build -t quay.io/rh_ee_lguoqing/toolbox:latest -f Dockerfile .
```

Packages are listed in [`Dockerfile`](Dockerfile). Edit the `dnf install` block to add or remove tools, then rebuild.

### Push

```bash
podman login quay.io
podman push quay.io/rh_ee_lguoqing/toolbox:latest
```

### Run — attach to a pod with `oc debug`

Example: debug CoreDNS on the same node as a client pod.

```bash
# 1. Pick the dns-default pod on the client's node
NODE=$(oc get pod -n <client-ns> <client-pod> -o jsonpath='{.spec.nodeName}')
DNS_POD=$(oc get pods -n openshift-dns -l dns.operator.openshift.io/daemonset-dns=default \
  --field-selector spec.nodeName="$NODE" -o jsonpath='{.items[0].metadata.name}')

# 2. Attach toolbox (shares network + process namespace with CoreDNS)
oc -n openshift-dns debug -it "$DNS_POD" \
  --image=quay.io/rh_ee_lguoqing/toolbox:latest \
  --target=dns \
  --share-processes \
  --profile=netadmin
```

Inside the debug shell:

```bash
# verify you see CoreDNS
ps aux | grep coredns

# capture DNS on the pod interface
tcpdump -i eth0 -n -vv 'port 53 or port 5353'

# eBPF examples (need sufficient capabilities)
bpftrace --version
/usr/share/bcc/tools/biosnoop
```

| Flag | Purpose |
| ---- | ------- |
| `--target=dns` | Join existing pod; share its network namespace |
| `--share-processes` | See and trace processes in the target container |
| `--profile=netadmin` | Capabilities for `tcpdump` on interfaces |

Generic pattern for any pod:

```bash
oc -n <namespace> debug -it <pod> \
  --image=quay.io/rh_ee_lguoqing/toolbox:latest \
  --target=<container-name> \
  --share-processes \
  --profile=netadmin
```

More DNS examples: [OpenShift network tracing — CoreDNS](../../networking/ocp-network-tracing/ocp-net-tracing.md#coredns-in-the-cluster).

---

## 2. Kernel-matched eBPF image — build and run

Use when **BCC/bpftrace** must compile against headers that match the **exact OCP worker kernel** (block I/O lab, privileged tracing).

**Requires:** RHEL machine with Podman and an active Red Hat subscription (build pulls pinned `kernel-core` / `kernel-headers` from RHEL repos).

### Build

```bash
# 1. Get worker kernel version
KERNEL=$(oc get nodes -l node-role.kubernetes.io/worker -o name | head -1 | xargs -I{} \
  oc debug {} -- chroot /host uname -r)
echo "$KERNEL"   # e.g. 5.14.0-570.12.1.el9_6.x86_64

# 2. Build (writes Dockerfile.ebpf so the Fedora toolbox Dockerfile is untouched)
cd ocp-lab/learning/ebpf
./build-ebpf.sh -k "$KERNEL" -o Dockerfile.ebpf --no-build

podman build --volume /etc/pki/entitlement:/etc/pki/entitlement:ro,Z \
  --volume /etc/rhsm:/etc/rhsm:ro,Z \
  --volume /etc/yum.repos.d/redhat.repo:/etc/yum.repos.d/redhat.repo:ro,Z \
  -t ebpf-9.6 -f Dockerfile.ebpf .
```

Or one step (overwrites `Dockerfile` — run `git checkout -- Dockerfile` afterward):

```bash
./build-ebpf.sh -k 5.14.0-570.12.1.el9_6.x86_64
```

Image is tagged **`ebpf-<ubi-version>`** (e.g. `ebpf-9.6` from `el9_6` in the kernel string). Contains **bpftrace**, **bpftool**, **bcc**, and matched kernel headers.

### Push

```bash
podman tag ebpf-9.6 quay.io/rh_ee_lguoqing/ebpf_96:latest
podman login quay.io
podman push quay.io/rh_ee_lguoqing/ebpf_96:latest
```

### Run — privileged pod

Apply a pod spec that uses the image, e.g. [`templates/cnv/ddpod.yaml`](../../templates/cnv/ddpod.yaml):

```bash
oc apply -f templates/cnv/ddpod.yaml
oc exec -it dd-experiment -- bash
```

Inside the pod:

```bash
bpftrace --version
bpftool prog list
```

For block I/O tracing, use **`bio*`** tools if you add `bcc-tools` to the image, or run **`bpftrace`** one-liners. The sample `ddpod.yaml` mounts `/sys/kernel/debug` and a block device for storage experiments.

---

## BCC tools (quick reference)

**bcc-tools** (in the Fedora toolbox) are prebuilt eBPF scripts from [iovisor/bcc](https://github.com/iovisor/bcc):

| Path | Contents |
| ---- | -------- |
| `/usr/share/bcc/tools/` | Scripts — `execsnoop`, `biolatency`, `biotop`, `biosnoop`, … |
| `man bcc-<toolname>` | Man pages |
| `/usr/share/bcc/tools/doc/` | Examples |

**Block I/O:** `biolatency` (latency histogram), `biotop` (top I/O processes), `biosnoop` (per-I/O trace).

**Alternative:** [libbpf-tools](https://github.com/iovisor/bcc/tree/master/libbpf-tools) (`bpf-biolatency`, etc.) — smaller CO-RE binaries, less kernel-header coupling. Not in the current Dockerfile; add `libbpf-tools` if you want them.

---

## Troubleshooting

**Podman storage mismatch** (wrong `$HOME` in error):

```bash
rm -rf ~/.local/share/containers/storage ~/.config/containers
podman info
```

**Two Dockerfiles in this directory:** [`Dockerfile`](Dockerfile) = Fedora toolbox (git). `Dockerfile.ebpf` or generated `Dockerfile` = UBI kernel-matched image from `build-ebpf.sh`.

---

## Related docs

- [OpenShift network tracing](../../networking/ocp-network-tracing/ocp-net-tracing.md) — DNS path, OVN, tcpdump from client pods
- [nettools-fedora](../../networking/ocp-network-tracing/README.md) — lighter toolbox without eBPF packages
- [DNS resolution debugging](../../networking/dns-resolution-issue/dns-resolution-error.md)
