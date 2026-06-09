# eBPF lab notes

Lab tooling for eBPF development and in-cluster debugging (including CoreDNS packet capture).

## Table of contents

- [eBPF image build](#ebpf-image-build)
- [Debug image (tcpdump, bpftrace, …)](#debug-image-tcpdump-bpftrace-)
- [CoreDNS: `kubectl debug` with shared processes](#coredns-kubectl-debug-with-shared-processes)
- [CoreDNS: tcpdump on the pod](#coredns-tcpdump-on-the-pod)
- [Node-level: DNS errors with tshark](#node-level-dns-errors-with-tshark)

---

## eBPF image build

`build-ebpf.sh` creates a container with kernel headers and bcc/bpftrace matched to a specific kernel version. It extracts the appropriate UBI version from the kernel string and builds the image.

### Prerequisites

- A RHEL/CentOS machine or VM with:
  - Podman installed (`dnf install podman` if not already installed)
  - Valid Red Hat subscription activated
  - `subscription-manager` properly authenticated
  - Red Hat Subscription: The build process requires a valid Red Hat subscription since it needs to access RHEL repositories.
  - Subscription Mount: The script mounts the following directories from your host:
  - `/etc/pki/entitlement`
  - `/etc/rhsm`
  - `/etc/yum.repos.d/redhat.repo`


### Installation

```bash
git clone git@github.com:gqlo/ocp-workspace.git
cd ocp-workspace/learning/ebpf
```

The script will:

1. Generate a Dockerfile for the specified kernel version
2. Extract the appropriate UBI version from the kernel string
3. Install dependencies (kernel headers, bpftrace, bpftool, etc.)
4. Build the container image

### Basic usage

```bash
./build-ebpf.sh -k 5.14.0-427.40.1.el9_4.x86_64
```

---

## Debug image (tcpdump, bpftrace, …)

The **`dns`** container in **`dns-default`** is a minimal CoreDNS image: it has no **`tcpdump`**, **`strace`**, or shell utilities. For packet capture and process inspection, attach an ephemeral debug container with a toolbox image built from [`Dockerfile`](Dockerfile).

Published image: **`quay.io/rh_ee_lguoqing/toolbox:latest`** (Fedora 40 base).

### What's in the image

| Category | Packages |
| -------- | -------- |
| eBPF / tracing | `bpftrace`, `bcc-tools`, `kernel-devel`, `perf`, `strace`, `ltrace`, `blktrace` |
| Network capture | `tcpdump`, `wireshark-cli`, `conntrack-tools` |
| IP / DNS / routing | `iproute`, `iputils`, `bind-utils`, `net-tools`, `bridge-utils`, `ethtool` |
| Network testing | `curl`, `wget`, `nmap`, `nmap-ncat`, `nc`, `iperf3`, `socat`, `traceroute`, `telnet`, `mtr` |
| Process / system | `procps-ng`, `psmisc`, `sysstat`, `lsof`, `pciutils`, `iftop`, `iotop`, `htop` |
| Storage / disk | `gdisk`, `hdparm`, `smartmontools`, `nvme-cli` |
| Shell / utilities | `util-linux`, `passwd`, `bash-completion`, `vim`, `less` |

To add or remove tools, edit the `dnf install` list in [`Dockerfile`](Dockerfile), then rebuild and push (steps below). Do not rely on `dnf install` inside a running debug pod — ephemeral containers are discarded when the session ends.

### Prerequisites

- Podman (`dnf install podman`)
- Network access to pull **`fedora:40`** and push to Quay
- Quay credentials with **write** access to **`quay.io/rh_ee_lguoqing/toolbox`** (for push; pull may work without login if the repo is public)

### Build the toolbox image

```bash
cd ocp-lab/learning/ebpf   # or: cd ocp-workspace/learning/ebpf

podman build -t quay.io/rh_ee_lguoqing/toolbox:latest -f Dockerfile .
```

Optional version tag (recommended when changing the package list):

```bash
podman build -t quay.io/rh_ee_lguoqing/toolbox:v2 -f Dockerfile .
podman tag quay.io/rh_ee_lguoqing/toolbox:v2 quay.io/rh_ee_lguoqing/toolbox:latest
```

### Test locally before pushing

```bash
podman run --rm -it quay.io/rh_ee_lguoqing/toolbox:latest bash

# inside the container — spot-check a few tools
tcpdump --version
bpftrace --version
dig -v
conntrack -V
```

### Push to Quay

```bash
podman login quay.io
podman push quay.io/rh_ee_lguoqing/toolbox:latest
# if you tagged a version:
# podman push quay.io/rh_ee_lguoqing/toolbox:v2
```

Clusters pick up the new image on the next `kubectl debug` session that references **`quay.io/rh_ee_lguoqing/toolbox`**.

### Pull only (consumer)

If you only need the published image on a workstation or node:

```bash
podman pull quay.io/rh_ee_lguoqing/toolbox:latest
```

---

## CoreDNS: `kubectl debug` with shared processes

Pick a **`dns-default`** pod (one per node). To use the pod on the same node as a workload:

```bash
NODE=$(kubectl get pod -n <client-ns> <client-pod> -o jsonpath='{.spec.nodeName}')
kubectl get pods -n openshift-dns -l dns.operator.openshift.io/daemonset-dns=default \
  --field-selector spec.nodeName="$NODE" -o wide
```

Attach a debug container to the **`dns`** container with a **shared process namespace** so **`ps`**, **`strace`**, and **`bpftrace`** can see CoreDNS (PID 1 in that container):

```bash
kubectl -n openshift-dns debug -it dns-default-2hs8l \
  --image=quay.io/rh_ee_lguoqing/toolbox \
  --target=dns \
  --share-processes \
  --profile=netadmin
```

| Flag | Purpose |
| ---- | ------- |
| **`--target=dns`** | Ephemeral container joins the existing pod; shares the pod network namespace with CoreDNS. |
| **`--share-processes`** | Process namespace shared with **`dns`** — you can see **`coredns`** and attach tracers. |
| **`--profile=netadmin`** | Relaxes capabilities so **`tcpdump`** can capture on **`eth0`** (requires cluster support for debug profiles). |
| **`--image=…/toolbox`** | Image with **`tcpdump`** and other tools (not in the CoreDNS image). |

After the session ends, remove the ephemeral debug container if it remains:

```bash
kubectl -n openshift-dns get pod dns-default-2hs8l -o jsonpath='{.spec.ephemeralContainers[*].name}{"\n"}'
# kubectl -n openshift-dns delete pod dns-default-2hs8l  # only if stuck; DaemonSet recreates
```

Verify shared process namespace inside the debug shell:

```bash
ps aux | grep -E 'coredns|PID'
ss -tupln | grep 5353
```

---

## CoreDNS: tcpdump on the pod

Inside the debug shell, capture on **`eth0`** (the pod’s cluster interface). CoreDNS listens on **5353** inside the pod; the **`dns-default` Service** maps cluster port **53 → 5353**. Client traffic arriving at the pod therefore shows as **UDP/TCP 5353** in tcpdump (often labeled **`.mdns`** in `/etc/services` — that is port 5353, not multicast mDNS).

### Capture all DNS on the pod interface

```bash
tcpdump -i eth0 -n -vv 'port 53 or port 5353'
```

### Narrow filters

Only traffic to/from this CoreDNS pod IP (replace with `kubectl get pod -o wide`):

```bash
POD_IP=$(kubectl -n openshift-dns get pod dns-default-2hs8l -o jsonpath='{.status.podIP}')
tcpdump -i eth0 -n -vv host "$POD_IP" and udp port 5353
```

Only upstream forwarding (CoreDNS → node resolver), e.g. **`10.1.48.25:53`**:

```bash
tcpdump -i eth0 -n -vv 'udp port 53 and not port 5353'
```

Filter by name while capturing:

```bash
tcpdump -i eth0 -n -vv udp port 5353 | grep -E 'ntp.org|rhsm|cdn.redhat'
```

### What you should see

Typical flow for an **external** name (cache miss):

```text
10.129.2.119.xxxxx > 10.129.2.7.5353   # client → CoreDNS (A / AAAA)
10.129.2.7.xxxxx > 10.1.48.25.53       # CoreDNS → upstream
10.1.48.25.53 > 10.129.2.7.xxxxx       # upstream reply
10.129.2.7.5353 > 10.129.2.119.xxxxx   # CoreDNS → client
```

For a **cache hit**, client ↔ CoreDNS lines appear without upstream **`10.1.48.25`** in between.

Map a client IP to a pod:

```bash
kubectl get pod -A -o wide | grep 10.129.2.124
```

### `[bad udp cksum]` on replies from CoreDNS

Packets **from** the pod often show **`[bad udp cksum …]`** when capturing inside the pod; packets **from clients** show **`[udp sum ok]`**. This is usually **checksum offload** on transmit, not real corruption.

### Contrast: capture from a client pod

From a normal workload pod, queries go to the **Service ClusterIP** on port **53** (not the CoreDNS pod IP):

```bash
kubectl exec -n <ns> <pod> -- tcpdump -i eth0 -nn 'udp port 53'
# Example line: 10.129.2.208 > 172.30.0.10.53: A? ...
```

See also [ocp-net-tracing.md](../networking/ocp-network-tracing/ocp-net-tracing.md) (DNS tracing from a client pod).

---

## Node-level: DNS errors with tshark

Use this on the **OpenShift node** (not inside the CoreDNS debug pod) when you need to see **failed DNS responses** for traffic involving an upstream resolver. The toolbox image includes **`tshark`** via **`wireshark-cli`**; for a host NIC you typically run on the node itself (or any host with that interface and `tshark` installed).

Replace **`eno12409np1`** with the node interface that carries resolver traffic (`ip route get 10.1.48.1` or `nmcli dev status`), and **`10.1.48.1`** with your upstream DNS IP (same role as **`10.1.48.25`** in the tcpdump examples above).

### Live monitor: non-success DNS responses

```bash
sudo tshark -i eno12409np1 -f "host 10.1.48.1 and port 53" \
  -Y "dns.flags.response == 1 && dns.flags.rcode != 0" \
  -T fields -e frame.number -e frame.time_relative -e ip.src -e ip.dst \
  -e dns.qry.name -e dns.flags.rcode
```

Stop with **Ctrl+C**. For a saved capture, omit **`-i`** and **`-f`**, and add **`-r capture.pcap`**.

| Part | Purpose |
| ---- | ------- |
| **`-i eno12409np1`** | Capture on the node NIC. |
| **`-f "host … and port 53"`** | **Capture filter** (BPF, in kernel): only DNS packets involving that host—applied before decode; keeps CPU/disk low. |
| **`-Y "dns.flags.response == 1 && …"`** | **Display filter**: DNS **responses** only, with **RCODE ≠ 0** (not `NOERROR`). |
| **`-T fields -e …`** | Tab-separated columns instead of the default one-line summary. |

| Field | Meaning |
| ----- | ------- |
| `frame.number` | Packet index in this capture session. |
| `frame.time_relative` | Seconds since capture started. |
| `ip.src` / `ip.dst` | Source and destination (client vs resolver depends on direction). |
| `dns.qry.name` | Queried name (from the response). |
| `dns.flags.rcode` | DNS response code (numeric). |

Common **RCODE** values (non-zero lines match the **`-Y`** filter):

| RCODE | Name | Typical meaning |
| ----- | ---- | ----------------- |
| 0 | NOERROR | Success (excluded by the display filter) |
| 2 | SERVFAIL | Resolver or upstream failure |
| 3 | NXDOMAIN | Name does not exist |
| 5 | REFUSED | Query refused |

**Capture vs display:** **`-f`** limits what the kernel delivers to tshark; **`-Y`** only affects printed output. Queries and successful replies may still be captured if they match **`-f`** but will not appear in the field output unless they pass **`-Y`**.

