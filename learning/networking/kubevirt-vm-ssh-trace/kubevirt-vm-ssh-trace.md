# KubeVirt VM SSH packet tracing

## Last Updated

**Started:** 2026-07-30 09:18  
**Reorganized:** 2026-07-30 10:33 — tracing flow ordered **pod first, then guest**; live pod NICs for fedora104  
**Updated:** 2026-07-30 15:27 — live pod NICs for **fedora166** (`virt-launcher-fedora166-4jcns`)  
**Updated:** 2026-07-30 15:34 — pod `tcpdump` needs **node nsenter**; ephemeral debug lacks `NET_RAW` under restricted PSS  
**Updated:** 2026-07-30 15:50 — capture via **podman** + `ocp-trace:4.22.0` into compute netns (RHCOS has no tcpdump)

## Catalog

- [Goal](#goal)
- [End-to-end path](#end-to-end-path)
- [Lab context](#lab-context)
  - [Targets](#targets)
- [1. Pod tracing (virt-launcher — see VMI / pod IP)](#1-pod-tracing-virt-launcher--see-vmi--pod-ip)
  - [Netns layout](#netns-layout-same-for-both-vms)
  - [Live pod NICs — fedora104](#live-pod-nics--fedora104-compute-netns)
  - [Live pod NICs — fedora166](#live-pod-nics--fedora166-compute-netns)
  - [Masquerade NAT](#masquerade-nat-nft-in-compute-netns)
  - [How to enter the pod netns](#how-to-enter-the-pod-netns)
  - [Capture on eth0](#capture-on-eth0)
  - [Finding: VMI status IP vs pod IP](#finding-vmi-status-ip-vs-pod-ip)
- [2. VM guest tracing (after DNAT — see 10.0.2.2)](#2-vm-guest-tracing-after-dnat--see-10022)
  - [Guest addresses](#guest-addresses)
  - [Working capture — fedora104](#working-capture--fedora104-guest)
  - [How to read the guest IPs](#how-to-read-the-guest-ips)
  - [fedora166 guest notes](#fedora166-guest-notes)
- [Checklist](#checklist)
  - [Stage 1 — Pod](#stage-1--pod)
  - [Stage 2 — Guest](#stage-2--guest)
- [Working notes](#working-notes)
  - [Hypothesis](#hypothesis)
  - [Timeline](#timeline)
  - [Open questions](#open-questions)
- [Related labs](#related-labs)

## Goal

Document the SSH packet path through a KubeVirt masquerade VM in two capture stages:

1. **Pod (virt-launcher)** — before DNAT; see the **VMI/pod IP**
2. **VM guest** — after DNAT; see the **masquerade guest IP** `10.0.2.2`

Working reference VM: **`fedora104`**. Problem / status-IP anomaly: **`fedora166`**.

## End-to-end path

```text
SSH client (e.g. 10.129.1.133)
  -> OVN
  -> [1] virt-launcher eth0     dst = POD/VMI IP :22     ← capture HERE to see VMI IP
  -> nft KUBEVIRT_PREINBOUND    DNAT -> 10.0.2.2:22
  -> k6t-eth0 / tap0
  -> [2] guest enp1s0           dst = 10.0.2.2:22        ← capture HERE (post-NAT)
  -> sshd
```

| Stage | Where | Dest IP on the wire | Tool |
| ----- | ----- | ------------------- | ---- |
| **1. Pod** | virt-launcher `eth0` | Pod / VMI IP (e.g. `10.149.1.166`) | `oc debug --target=compute` or `nsenter` + `tcpdump` |
| **2. Guest** | guest `enp1s0` | Masquerade `10.0.2.2` | `virtctl console` + `tcpdump` |

DNAT rewrites **destination** only. Source (client pod IP) stays the same on both sides.

---

## Lab context

| Item | Value |
| ---- | ----- |
| Namespace | `vm-migration` |
| CNI | OVN-Kubernetes |
| Cluster network | `10.128.0.0/10` (`10.128.0.0`–`10.191.255.255`) |
| Service network | `172.30.0.0/16` |
| Binding | pod network + **masquerade** |

### Targets

| | `fedora104` (working) | `fedora166` (anomaly) |
| --- | --- | --- |
| Node | `d21-h31-000-r650` | `e45-h07-000-r650` (`10.1.48.215`) |
| virt-launcher | `virt-launcher-fedora104-74f96` | `virt-launcher-fedora166-4jcns` |
| **Pod IP** (`oc get pod`) | `10.149.1.166` | `10.128.49.109` |
| **VMI status IP** (`oc get vmi`) | `10.149.1.166` (matches pod) | **`10.0.2.2`** (wrong for operators) |
| Guest `enp1s0` | `10.0.2.2/24` | `10.0.2.2/24` |
| SSH NodePort | — | `fedora166-ssh` `22:32182/TCP` |

Always take the reachable address from the **Running** virt-launcher pod IP (or Service), not from a VMI status IP outside `10.128.0.0/10`.

```bash
NS=vm-migration
# pick VM=fedora104 or fedora166
oc get vmi -n "$NS" "$VM" -o wide
oc get pod -n "$NS" -l kubevirt.io/domain="$VM" --field-selector=status.phase=Running -o wide
```

Probe (use **pod IP**):

```bash
nc -vz 10.149.1.166 22    # fedora104
nc -vz 10.128.49.109 22   # fedora166 — NOT 10.0.2.2
```

---

## 1. Pod tracing (virt-launcher — see VMI / pod IP)

Capture on **`eth0` before masquerade DNAT**. This is the only place guest-side tools will not show: the cluster-facing VMI/pod IP.

### Netns layout (same for both VMs)

```text
eth0       <pod IP>/20     ← OVN / cluster side  (VMI/pod IP lives here)
k6t-eth0   10.0.2.1/24     ← masquerade gateway
tap0       L2, master k6t-eth0
```

### Live pod NICs — `fedora104` (compute netns)

Captured via `oc debug … --target=compute` on `virt-launcher-fedora104-74f96` (2026-07-30):

```text
1: lo: <LOOPBACK,UP,LOWER_UP>
    inet 127.0.0.1/8

2: eth0@if421: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400
    link/ether 0a:58:0a:95:01:a6
    inet 10.149.1.166/20 brd 10.149.15.255 scope global eth0
    inet6 fe80::858:aff:fe95:1a6/64 scope link

3: k6t-eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400
    link/ether 02:00:00:00:00:00
    inet 10.0.2.1/24 brd 10.0.2.255 scope global k6t-eth0
    inet6 fe80::ff:fe00:0/64 scope link

4: tap0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400 master k6t-eth0
    link/ether 62:07:d6:68:98:1c
    inet6 fe80::6007:d6ff:fe68:981c/64 scope link
```

| Interface | Address | Role |
| --------- | ------- | ---- |
| `eth0` | **`10.149.1.166/20`** | Pod / VMI IP — cluster side; capture SSH **here** to see VMI IP |
| `k6t-eth0` | `10.0.2.1/24` | Masquerade bridge / guest gateway |
| `tap0` | L2 only (master `k6t-eth0`) | Toward QEMU / guest |

### Live pod NICs — `fedora166` (compute netns)

Captured via `kubectl debug … --target=compute` on `virt-launcher-fedora166-4jcns` (2026-07-30 ~15:27):

```bash
kubectl debug -it virt-launcher-fedora166-4jcns \
  --image="$OCP_TRACE" \
  --target=compute \
  -n vm-migration
# inside debugger:
ip a
```

```text
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
    inet6 ::1/128 scope host

2: eth0@if354: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400 qdisc noqueue state UP group default qlen 1000
    link/ether 0a:58:0a:80:31:6d brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 10.128.49.109/20 brd 10.128.63.255 scope global eth0
    inet6 fe80::858:aff:fe80:316d/64 scope link

3: k6t-eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400 qdisc noqueue state UP group default qlen 1000
    link/ether 02:00:00:00:00:00 brd ff:ff:ff:ff:ff:ff
    inet 10.0.2.1/24 brd 10.0.2.255 scope global k6t-eth0
    inet6 fe80::ff:fe00:0/64 scope link

4: tap0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400 qdisc mq master k6t-eth0 state UP group default qlen 1000
    link/ether 1e:20:0a:f5:02:8b brd ff:ff:ff:ff:ff:ff
    inet6 fe80::1c20:aff:fef5:28b/64 scope link
```

| Interface | Address | Role |
| --------- | ------- | ---- |
| `eth0` | **`10.128.49.109/20`** | Real pod IP — cluster side; capture SSH **here** (not VMI status `10.0.2.2`) |
| `k6t-eth0` | `10.0.2.1/24` | Masquerade bridge / guest gateway (same as fedora104) |
| `tap0` | L2 only (master `k6t-eth0`) | Toward QEMU / guest |

Same netns shape as fedora104; only cluster-facing `eth0` differs. Confirms the anomaly is **VMI status advertising guest `10.0.2.2`**, not a broken launcher layout.

### Masquerade NAT (nft in compute netns)

```nft
# inbound on eth0 → DNAT to guest
chain KUBEVIRT_PREINBOUND {
  dnat to 10.0.2.2
}
# guest 10.0.2.2 outbound → masquerade as pod IP
```

So on `eth0`:

```text
Before DNAT:  client → <POD_IP>:22
After DNAT:   client → 10.0.2.2:22   (seen on k6t-eth0 / tap0 / guest)
```

### How to enter the pod netns

**Option A — ocp-trace debug container** (shares netns with `compute`):

Good for `ip a` / inspection. **Not enough for `tcpdump`** on this cluster.

```bash
OCP_TRACE="quay.io/rh_ee_lguoqing/ocp-trace:$(oc get clusterversion version -o jsonpath='{.status.desired.version}')"

oc debug -it virt-launcher-fedora104-74f96 \
  -n vm-migration \
  --image="$OCP_TRACE" \
  --target=compute

# anomaly VM:
kubectl debug -it virt-launcher-fedora166-4jcns \
  -n vm-migration \
  --image="$OCP_TRACE" \
  --target=compute
```

Observed (2026-07-30 ~15:34, `vm-migration` / **restricted:latest**):

```text
# default debug (non-root):
tcpdump: eth0: You don't have permission to capture on that device
(socket: Operation not permitted)

# --custom with runAsUser:0 + NET_RAW/NET_ADMIN:
Warning: would violate PodSecurity "restricted:latest": ... runAsUser=0 ...
  ... must not include "NET_ADMIN", "NET_RAW", "SYS_PTRACE" ...
Warning: container's runAsUser breaks non-root policy
```

`--custom` does **not** unlock capture here — PSS blocks the privileges `tcpdump` needs.

Also: after `chroot /host` on RHCOS, `tcpdump` is **not installed**. Do **not** `nsenter … tcpdump` on the host binary.

**Option B — `podman` + ocp-trace into the compute netns** (required for pod `tcpdump`):

Full write-up: [eBPF — Permission denied / restricted PSS](../../ebpf/README.md#permission-denied--restricted-pss).

```bash
NS=vm-migration
POD=virt-launcher-fedora166-4jcns
NODE=$(oc get pod -n "$NS" "$POD" -o jsonpath='{.spec.nodeName}')
CRIID=$(oc get pod -n "$NS" "$POD" -o jsonpath='{.status.containerStatuses[?(@.name=="compute")].containerID}' | sed 's|cri-o://||')

oc debug node/"$NODE"
# then:
chroot /host
PID=$(crictl inspect "$CRIID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["pid"])')

podman run --rm -it \
  --cap-add=NET_RAW --cap-add=NET_ADMIN \
  --network=ns:/proc/${PID}/ns/net \
  quay.io/rh_ee_lguoqing/ocp-trace:4.22.0 \
  tcpdump -i eth0 tcp port 22 -vv
# or: tcpdump -ni eth0 host 10.128.49.109 and tcp port 22 -vv
```

Same pattern for fedora104 — swap `POD` / filter host `10.149.1.166`.

### Capture on `eth0`

Run via **Option B** (`podman` into compute netns), not the non-root ephemeral debugger:

```bash
# inside the ocp-trace container attached to the netns:
ip -br addr
# fedora104 live: eth0 = 10.149.1.166/20, k6t-eth0 = 10.0.2.1/24, tap0 master k6t-eth0
# fedora166 live: eth0 = 10.128.49.109/20, k6t-eth0 = 10.0.2.1/24, tap0 master k6t-eth0

tcpdump -ni eth0 host 10.149.1.166 and tcp port 22 -vv   # fedora104
tcpdump -ni eth0 host 10.128.49.109 and tcp port 22 -vv  # fedora166
```

**Expected (working path):**

```text
<client> → 10.149.1.166:22   Flags [S]     # VMI/pod IP visible here
10.149.1.166:22 → <client>   Flags [S.]
```

Optional mid-NAT views in the same netns:

```bash
tcpdump -ni k6t-eth0 host 10.0.2.2 and tcp port 22 -vv
tcpdump -ni tap0 tcp port 22 -vv
```

### Finding: VMI status IP vs pod IP

```text
oc get vmi -o wide -n vm-migration | grep fedora166
fedora166    Running   10.0.2.2        ...   # guest-agent leaked masq IP into status
fedora1660   Running   10.147.17.102   ...   # normal: shows pod IP

oc get pod -n vm-migration -o wide | grep 'fedora166 '
virt-launcher-fedora166-4jcns   Running    10.128.49.109   # real reachability address
```

- Guest having `10.0.2.2` on `enp1s0` is **normal** for masquerade.
- Advertising `10.0.2.2` as *the* VMI IP in `oc get vmi` is **not** useful — use the pod IP.
- `fedora104` is healthy: VMI status IP == pod IP (`10.149.1.166`).

---

## 2. VM guest tracing (after DNAT — see `10.0.2.2`)

Capture on **`enp1s0` inside the guest**. You will **not** see the VMI/pod IP here; dest is always the masquerade address after DNAT.

### Guest addresses

**fedora166** (`ip a` on console):

```text
2: enp1s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400
    link/ether 02:87:76:7c:2c:f0
    inet 10.0.2.2/24 brd 10.0.2.255 scope global dynamic noprefixroute enp1s0
```

Same pattern on **fedora104**: guest wire IP is `10.0.2.2`; pod/VMI IP stays only on virt-launcher `eth0`.

```bash
virtctl console <vm> -n vm-migration
# inside:
ip -br addr
ss -lntp | grep :22
sudo journalctl -u sshd -e --no-pager
sudo tcpdump -ni enp1s0 tcp port 22 -vv
```

### Working capture — `fedora104` (guest)

Client pod `10.129.1.133` → (cluster) `10.149.1.166` → DNAT → guest `10.0.2.2`.

Guest tcpdump only shows the **post-NAT** view:

```text
# SYN to masquerade guest address (not 10.149.1.166)
10.129.1.133.36682 > 10.0.2.2.ssh: Flags [S]

# SYN-ACK from sshd
10.0.2.2.ssh > 10.129.1.133.36682: Flags [S.]

# ACK — TCP up
10.129.1.133.36682 > 10.0.2.2.ssh: Flags [.]

# SSH banners
10.0.2.2.ssh > 10.129.1.133.36682: ... SSH-2.0-OpenSSH_10.0
10.129.1.133.36682 > 10.0.2.2.ssh: ... SSH-2.0-OpenSSH_10.2
```

Full capture (2026-07-30 ~13:58 UTC):

```text
13:58:14.926928 IP 10.129.1.133.36682 > 10.0.2.2.ssh: Flags [S], seq 3363068696, win 65280, options [mss 1360,sackOK,TS val 3159128630 ecr 0,nop,wscale 7], length 0
13:58:14.926967 IP 10.0.2.2.ssh > 10.129.1.133.36682: Flags [S.], seq 2633601953, ack 3363068697, win 64704, options [mss 1360,sackOK,TS val 1127973196 ecr 3159128630,nop,wscale 9], length 0
13:58:14.928667 IP 10.129.1.133.36682 > 10.0.2.2.ssh: Flags [.], seq 1, ack 1, win 510, options [nop,nop,TS val 3159128632 ecr 1127973196], length 0
13:58:14.936489 IP 10.0.2.2.ssh > 10.129.1.133.36682: Flags [P.], seq 1:23, ack 1, win 127, length 22: SSH: SSH-2.0-OpenSSH_10.0
13:58:14.936962 IP 10.129.1.133.36682 > 10.0.2.2.ssh: Flags [.], seq 1, ack 23, win 510, length 0
13:58:14.966720 IP 10.129.1.133.36682 > 10.0.2.2.ssh: Flags [P.], seq 1:23, ack 23, win 510, length 22: SSH: SSH-2.0-OpenSSH_10.2
13:58:14.966734 IP 10.0.2.2.ssh > 10.129.1.133.36682: Flags [.], seq 23, ack 23, win 127, length 0
13:58:14.972785 IP 10.0.2.2.ssh > 10.129.1.133.36682: Flags [P.], seq 23:1023, ack 23, win 127, length 1000
13:58:14.978252 IP 10.129.1.133.36682 > 10.0.2.2.ssh: Flags [P.], seq 23:1479, ack 1023, win 503, length 1456
13:58:14.978283 IP 10.0.2.2.ssh > 10.129.1.133.36682: Flags [.], seq 1023, ack 1479, win 125, length 0
13:58:15.013210 IP 10.129.1.133.36682 > 10.0.2.2.ssh: Flags [P.], seq 1479:2711, ack 1023, win 503, length 1232
13:58:15.017638 IP 10.0.2.2.ssh > 10.129.1.133.36682: Flags [P.], seq 1023:2611, ack 2711, win 123, length 1588
13:58:15.017948 IP 10.129.1.133.36682 > 10.0.2.2.ssh: Flags [.], seq 2711, ack 2611, win 491, length 0
13:58:16.025992 IP 10.129.1.133.36682 > 10.0.2.2.ssh: Flags [F.], seq 2711, ack 2611, win 491, length 0
13:58:16.027492 IP 10.0.2.2.ssh > 10.129.1.133.36682: Flags [F.], seq 2611, ack 2712, win 123, length 0
13:58:16.027660 IP 10.129.1.133.36682 > 10.0.2.2.ssh: Flags [.], seq 2712, ack 2612, win 491, length 0
```

### How to read the guest IPs

| IP in guest tcpdump | Meaning |
| ------------------- | ------- |
| `10.129.1.133` | **Client** (another pod that ran `nc`/`ssh`) |
| `10.0.2.2` | **This guest** after DNAT (masquerade address) |
| *(absent)* `10.149.1.166` | VMI/pod IP — only visible on pod `eth0` (stage 1) |

Phrase for notes:

> Clients send SSH to the VMI/pod IP (`10.149.1.166:22`). That packet hits virt-launcher `eth0`, where masquerade DNAT rewrites the destination to `10.0.2.2:22`. A capture inside the guest therefore only shows the post-NAT view (`client → 10.0.2.2`).

### fedora166 guest notes

- `sshd` listener present
- `enp1s0` = `10.0.2.2/24` only
- Guest `tcpdump` showed 0 packets when no concurrent probe — re-test with `nc -vz 10.128.49.109 22` while capturing

---

## Checklist

### Stage 1 — Pod

- [ ] Enter compute netns via **podman + ocp-trace** on the node for capture (`oc debug --target=compute` is OK for `ip a` only)
- [ ] `eth0` address == Running pod IP
- [ ] `tcpdump -ni eth0 host <POD_IP> and tcp port 22` shows SYN to **pod/VMI IP**
- [ ] For `fedora166`, do not use status IP `10.0.2.2` as the filter host on `eth0`
- [ ] Do not rely on `--custom` root debug in `vm-migration` (restricted PSS blocks it)
- [ ] Do not expect host `tcpdump` after `chroot /host` (RHCOS) — use ocp-trace via `podman`

### Stage 2 — Guest

- [ ] `tcpdump -ni enp1s0 tcp port 22` while probing **pod IP**
- [ ] Dest is `10.0.2.2`; source is client pod IP
- [ ] TCP handshake + optional SSH banners (as on `fedora104`)
- [ ] If stage 1 OK and stage 2 empty → NAT/TAP issue; if both OK but login fails → auth

---

## Working notes

### Hypothesis

```
Masquerade: pod eth0 holds cluster IP; guest enp1s0 holds 10.0.2.2.
Guest tcpdump cannot show VMI IP — capture pod eth0 for that.
fedora104: status IP == pod IP (good). Guest wire still 10.0.2.2 (proven).
fedora166: status IP wrongly shows 10.0.2.2; real pod IP is 10.128.49.109.
```

### Timeline

| Time | Action | Result |
| ---- | ------ | ------ |
| 09:36 | Snapshot `fedora166` | pod `10.128.49.109`, status/guest `10.0.2.2` |
| 09:42 | Guest `ip a` / tcpdump on `fedora166` | only `10.0.2.2` on `enp1s0`; 0 pkts without probe |
| 09:51 | Compare peer VMIs | peers show pod IPs; only `fedora166` shows `10.0.2.2` in status |
| 09:58 | Guest tcpdump **fedora104** | full SSH to `10.0.2.2` from `10.129.1.133` |
| 10:31 | Reorganize doc | Stage 1 pod → Stage 2 guest |
| 10:33 | Pod `ip a` on **fedora104** compute netns | `eth0=10.149.1.166/20`, `k6t-eth0=10.0.2.1/24`, `tap0` master |
| 15:27 | Pod `ip a` on **fedora166** compute netns | `eth0=10.128.49.109/20`, `k6t-eth0=10.0.2.1/24`, `tap0` master — same layout as fedora104 |
| 15:33 | `tcpdump` in ephemeral debug | `Operation not permitted` (non-root / no `NET_RAW`) |
| 15:34 | `--custom` root + `NET_RAW`/`NET_ADMIN` | blocked by PodSecurity **restricted:latest** + non-root policy |
| 15:44 | `nsenter` then `tcpdump` on RHCOS | `tcpdump: command not found` |
| 15:50 | `podman run … --network=ns:/proc/$PID/ns/net` ocp-trace:4.22.0 | working capture path for restricted pods |

### Open questions

- Are failing clients targeting `fedora166`’s status IP `10.0.2.2`?
- Why did guest-agent win in VMI status for `fedora166`?
- Capture still needed on `fedora104`/`fedora166` **pod eth0** via **podman + ocp-trace** (ephemeral debug cannot tcpdump under restricted PSS)

## Related labs

- [`../ocp-network-tracing/ocp-net-tracing.md`](../ocp-network-tracing/ocp-net-tracing.md)
- [`../ebpf/README.md`](../../ebpf/README.md) — `ocp-trace` + `oc debug --target=compute`
- [`../localnet/example-vm.yaml`](../localnet/example-vm.yaml)
