# ocp-trace

**ocp-trace** is a debug container image for OpenShift: Driver Toolkit (RHCOS-matched kernel headers) plus eBPF, network capture, and shell utilities. Use it for **`oc debug`** into pods **or** on nodes.

| Image | Built by | Use for |
| ----- | -------- | ------- |
| **`quay.io/rh_ee_lguoqing/ocp-trace:<OCP-version>`** | [`build.sh`](build.sh) | Pod debug (tcpdump, CoreDNS) **and** node eBPF (bcc, bpftrace, bio*) |

Example: `quay.io/rh_ee_lguoqing/ocp-trace:4.22.0` — tag matches `oc get clusterversion version`. [`build.sh`](build.sh) also tags `:latest` for convenience.

**Why version tags?** The image is built on **Driver Toolkit**, which changes with each OCP release. Pin the tag to your cluster version so kernel headers stay matched after upgrades.

## Catalog

- [Quick start](#quick-start)
- [Published images (Quay)](#published-images-quay)
- [Build and push](#build-and-push)
- [Run — debug a pod](#run--debug-a-pod)
- [Run — long-lived pod](#run--long-lived-pod)
- [BCC tools catalog](#bcc-tools-catalog)
  - [Block I/O](#block-io)
  - [CPU and scheduler](#cpu-and-scheduler)
  - [Memory and process](#memory-and-process)
  - [Syscalls, security, and general tracing](#syscalls-security-and-general-tracing)
  - [Network and sockets](#network-and-sockets)
  - [Page cache and files](#page-cache-and-files)
  - [Filesystems](#filesystems)
  - [Databases](#databases)
  - [Language runtimes (USDT / uprobes)](#language-runtimes-usdt--uprobes)
  - [Suggested starting points (OpenShift)](#suggested-starting-points-openshift)
- [Troubleshooting](#troubleshooting)
- [Related docs](#related-docs)

---

## Quick start

Debug a worker node with ocp-trace:

```bash
OCP_TRACE=quay.io/rh_ee_lguoqing/ocp-trace:4.22.0
NODE=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')

oc debug "node/$NODE" --image="$OCP_TRACE"
```

Inside the debug shell:

```bash
ls /usr/share/bcc/tools/ | head
/usr/share/bcc/tools/biolatency    # Ctrl+C for histogram
```

---

## Published images (Quay)

Pre-built images on Quay — pull and use directly when your cluster version matches the tag.

| OCP version | Image |
| ----------- | ----- |
| **4.22.0** | `quay.io/rh_ee_lguoqing/ocp-trace:4.22.0` |

```bash
# use when cluster is 4.22.x
OCP_TRACE=quay.io/rh_ee_lguoqing/ocp-trace:4.22.0

# verify your cluster version first
oc get clusterversion version -o jsonpath='{.status.desired.version}{"\n"}'
```

If the tag does not match your cluster, build and push a new image with [`build.sh`](build.sh) (see below). `:latest` may also be updated on push but **prefer the version tag** for kernel-header alignment.

---

## Build and push

**Requires:** subscribed **RHEL** build host, `oc` logged into cluster, Quay push access.

```bash
cd ocp-lab/learning/ebpf
chmod +x build.sh

./build.sh
# tags: quay.io/rh_ee_lguoqing/ocp-trace:4.22.0  (from clusterversion)
# also:  quay.io/rh_ee_lguoqing/ocp-trace:latest

podman logout quay.io
podman login quay.io -u <your-quay-user>
podman push quay.io/rh_ee_lguoqing/ocp-trace:4.22.0
podman push quay.io/rh_ee_lguoqing/ocp-trace:latest
```

Set image reference for commands below:

```bash
OCP_TRACE="quay.io/rh_ee_lguoqing/ocp-trace:$(oc get clusterversion version -o jsonpath='{.status.desired.version}')"
echo "$OCP_TRACE"
```

Custom repo or tag:

```bash
./build.sh -t quay.io/<your-user>/ocp-trace:4.22.0
./build.sh --no-latest          # only the version tag, skip :latest
```

Dockerfile only:

```bash
./build.sh -n
```

Add/remove tools: edit [`packages.txt`](packages.txt), then rebuild.

**After OCP upgrade:** run `./build.sh` and push the new version tag.

---

## Run — debug a pod

Attach the debug container to a **specific container** in a pod with `--target=<container>`:

```bash
OCP_TRACE="quay.io/rh_ee_lguoqing/ocp-trace:$(oc get clusterversion version -o jsonpath='{.status.desired.version}')"

kubectl debug -it rook-ceph-osd-185-7f8c858f7f-zmw4v \
  --image="$OCP_TRACE" \
  --target=osd \
  -n openshift-storage
```

---

## Run — long-lived pod

Privileged pod on a worker for sustained node-level eBPF — [`ocp-trace-pod.yaml`](ocp-trace-pod.yaml):

```bash
OCP_VER=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
NODE=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')

sed -e "s/OCP_VERSION/${OCP_VER}/" -e "s/NODE_NAME/${NODE}/" ocp-trace-pod.yaml | oc apply -f -
oc wait --for=condition=Ready pod/ocp-trace-node --timeout=120s
oc exec -it ocp-trace-node -- bash
```

---

## BCC tools catalog

**bcc-tools** ships with ocp-trace under **`/usr/share/bcc/tools/`** (`bcc-tools` RPM). Each tool is a Python script from [iovisor/bcc](https://github.com/iovisor/bcc).

| How to run | Help |
| ---------- | ---- |
| `/usr/share/bcc/tools/<name>` | `man bcc-<name>` |
| `export PATH=/usr/share/bcc/tools:$PATH` then `<name>` | `/usr/share/bcc/tools/doc/<name>_example.txt` |

Inventory matches **`ls /usr/share/bcc/tools/`** on `quay.io/rh_ee_lguoqing/ocp-trace:4.22.0` (excludes `doc/`, `lib/`, and `.c` sources). **105 tools.**

```bash
ls /usr/share/bcc/tools/
export PATH=/usr/share/bcc/tools:$PATH   # optional

/usr/share/bcc/tools/biolatency    # Ctrl+C for histogram
/usr/share/bcc/tools/biosnoop
/usr/share/bcc/tools/execsnoop
man bcc-biolatency
bpftrace -e 'BEGIN { printf("ok\n"); exit() }'
```

### Block I/O

| Tool | Description |
| ---- | ----------- |
| **biolatency** | Block device I/O latency histogram |
| **biosnoop** | Trace block I/O with PID and latency |
| **biopattern** | Classify random vs sequential disk access |
| **biotop** | Top-like summary of block I/O by process |
| **bitesize** | Per-process I/O size histogram |
| **mdflush** | Trace md (RAID) flush events |

### CPU and scheduler

| Tool | Description |
| ---- | ----------- |
| **cpudist** | On- and off-CPU time per task (histogram) |
| **cpuunclaimed** | Sample run queues; estimate unclaimed idle CPU |
| **hardirqs** | Hard IRQ event time |
| **llcstat** | CPU last-level cache references and misses by process |
| **numasched** | Track process migration between NUMA nodes |
| **offcputime** | Off-CPU time summarized by kernel stack |
| **profile** | CPU usage via timed stack-trace sampling |
| **runqlen** | Run-queue length histogram |
| **runqslower** | Processes delayed on the run queue |
| **softirqs** | Soft IRQ event time |
| **wakeuptime** | Sleep-to-wakeup time by waker kernel stack |
| **wqlat** | Workqueue wait latency |

### Memory and process

| Tool | Description |
| ---- | ----------- |
| **compactsnoop** | Memory compaction events with PID and latency |
| **drsnoop** | Direct reclaim events with PID and latency |
| **execsnoop** | Trace new processes via `exec()` |
| **exitsnoop** | Trace process exit and fatal signals |
| **kvmexit** | KVM VM exit reasons and counts |
| **oomkill** | Trace OOM killer events |
| **pidpersec** | Count new processes (`fork`) per second |
| **rdmaucma** | RDMA userspace connection manager access events |
| **shmsnoop** | System V shared memory syscalls |
| **swapin** | Trace page swap-in events |

### Syscalls, security, and general tracing

| Tool | Description |
| ---- | ----------- |
| **argdist** | Histogram or count of function argument values |
| **bashreadline** | Print bash commands entered system-wide |
| **bindsnoop** | Trace IPv4/IPv6 `bind()` |
| **bpflist** | Processes with loaded BPF programs and maps |
| **capable** | Trace capability (`cap_`) checks |
| **deadlock** | Detect potential deadlocks in a running process |
| **funcinterval** | Time interval between calls to the same function |
| **funclatency** | Function latency distribution |
| **funcslower** | Slow kernel or user function calls |
| **klockstat** | Kernel mutex lock events and statistics |
| **mountsnoop** | Trace `mount` / `umount` syscalls |
| **opensnoop** | Trace `open()` syscalls |
| **stackcount** | Count function calls with stack traces |
| **statsnoop** | Trace `stat()` family syscalls |
| **syncsnoop** | Trace `sync()` syscall |
| **trace** | Trace arbitrary functions with filters |
| **tplist** | List kernel tracepoints and USDT probe formats |
| **ttysnoop** | Live output from a tty or pts device |

### Network and sockets

| Tool | Description |
| ---- | ----------- |
| **gethostlatency** | Latency of `getaddrinfo` / `gethostbyname` |
| **mptcpify** | Force applications to use MPTCP instead of TCP |
| **netqtop** | Packet distribution across NIC queues |
| **sofdsnoop** | File descriptors passed through Unix sockets |
| **sslsniff** | Sniff OpenSSL read/write data |
| **tcpaccept** | Trace passive TCP connections (`accept()`) |
| **tcpconnect** | Trace active TCP connections (`connect()`) |
| **tcpconnlat** | Active TCP connection latency |
| **tcpdrop** | Kernel TCP packet drops with details |
| **tcplife** | TCP session lifespan summary |
| **tcpretrans** | TCP retransmits and TLPs |
| **tcpstates** | TCP state transitions with durations |
| **tcpsubnet** | Aggregate TCP send throughput by subnet |
| **tcpsynbl** | TCP SYN backlog |
| **tcptop** | Top TCP send/recv throughput by host |
| **tcptracer** | Trace TCP `connect()`, `accept()`, `close()` |

### Page cache and files

| Tool | Description |
| ---- | ----------- |
| **cachestat** | Page cache hit/miss ratio |
| **dcsnoop** | Directory entry cache (dcache) lookups |
| **dcstat** | Dcache lookup statistics |
| **filegone** | Trace file deletion or rename |
| **filelife** | Lifespan of short-lived files |
| **fileslower** | Slow synchronous file reads and writes |
| **filetop** | File reads/writes by filename and process |
| **readahead** | Read-ahead cache effectiveness |

### Filesystems

| Tool | Description |
| ---- | ----------- |
| **ext4dist** | ext4 operation latency histogram |
| **f2fsslower** | Slow F2FS operations |
| **nfsslower** | Slow NFS operations |
| **vfscount** | Count VFS calls |
| **vfsstat** | VFS call counts (column output) |
| **xfsdist** | XFS operation latency histogram |
| **xfsslower** | Slow XFS operations |

### Databases

| Tool | Description |
| ---- | ----------- |
| **dbstat** | MySQL/PostgreSQL query latency histogram |
| **mysqld_qslower** | Slow MySQL server queries (USDT) |

### Language runtimes (USDT / uprobes)

Wrappers around BCC `lib` helpers. Require the target language runtime and often root/CAP_SYS_ADMIN.

| Java | Node.js | Perl | PHP | Python | Ruby | Tcl | Other |
| ---- | ------- | ---- | --- | ------ | ---- | --- | ----- |
| `javaflow` | `nodegc` | `perlcalls` | `phpflow` | `pythonflow` | `rubycalls` | `tclcalls` | `cobjnew` |
| `javagc` | `nodestat` | `perlflow` | `phpstat` | `pythongc` | `rubyflow` | `tclflow` | `ppchcalls` |
| `javaobjnew` | | `perlstat` | | `pythonstat` | `rubygc` | `tclobjnew` | |
| `javastat` | | | | | `rubyobjnew` | `tclstat` | |
| `javathreads` | | | | | `rubystat` | | |

### Suggested starting points (OpenShift)

| Goal | Tools |
| ---- | ----- |
| Disk / PVC latency on a node | `biolatency`, `biosnoop`, `biotop`, `biopattern` |
| DNS / network from a pod debug shell | `tcpconnect`, `gethostlatency`, plus `tcpdump` |
| Slow filesystem on RHCOS (XFS) | `xfsdist`, `xfsslower`, `fileslower` |
| Scheduler / CPU wait | `runqlen`, `runqslower`, `offcputime`, `profile` |
| New processes / suspicious exec | `execsnoop`, `opensnoop` |
| Capabilities / security | `capable` |

Upstream: [bcc README — Tools](https://github.com/iovisor/bcc#tools) · [bcc tutorial](https://github.com/iovisor/bcc/blob/master/docs/tutorial.md)

---

## Troubleshooting

| Problem | Fix |
| ------- | --- |
| Wrong/missing kernel headers after upgrade | Rebuild and use new **version tag**, not an old one |
| `No package matches '…'` during `./build.sh` | Package not in RHEL 9 BaseOS/AppStream — remove from [`packages.txt`](packages.txt) |
| `cannot install the best candidate` / `curl-minimal` vs `curl` | DTK ships **curl-minimal** — do not install `curl` in packages.txt |
| `unauthorized` on push | Login as Quay user with write access (not cluster robot) |
| Debug exits immediately | Add **`-it`** to `oc debug` |

```bash
podman login quay.io --get-login
oc get clusterversion version -o jsonpath='{.status.desired.version}{"\n"}'
```

---

## Related docs

- [OpenShift Driver Toolkit](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/specialized_hardware_and_driver_enablement/driver-toolkit)
- [OpenShift network tracing](../../networking/ocp-network-tracing/ocp-net-tracing.md)
