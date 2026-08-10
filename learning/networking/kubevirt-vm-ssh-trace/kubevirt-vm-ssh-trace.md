# KubeVirt VM SSH packet tracing

**2026-07-30** — working `fedora104` vs `fedora166` (`vm-migration`, masquerade).

## Conclusion — root cause

**`virtctl ssh` fails on `fedora166` because the VMI status IP is the guest masquerade address `10.0.2.2`, not the virt-launcher pod IP `10.128.49.109`.**

Port-forward (what `virtctl ssh` uses) dials the **VMI status IP**. When that IP is wrong:

```text
dial tcp 10.0.2.2:22: connect: connection timed out
```

Nothing reaches launcher `eth0`/`tap0`. The guest having `10.0.2.2` on `enp1s0` is normal for masquerade; advertising it in `oc get vmi` is the bug.

| | fedora104 | fedora166 |
| --- | --- | --- |
| VMI status IP | `10.149.1.166` | **`10.0.2.2`** |
| Pod IP | `10.149.1.166` | `10.128.49.109` |
| `virtctl ssh` / portforward | works | fails (dials `10.0.2.2`) |
| `nc` to **pod IP** | works | works |

Launcher networking and DNAT are healthy on both VMs. Fix targeting (use pod IP / fix status IP), not the NAT path.

The virt-launcher pod IP is correctly assigned and reachable (`nc` to `<pod-IP>:22` works). VMI ends up with the guest private IP (`10.0.2.2`) likely due to the guest-agent fallback when the pod IP is missing from VMI status. `virtctl` dials that status IP and times out. See [kubevirt#16421](https://github.com/kubevirt/kubevirt/issues/16421) (Omit private IPs from VMI interface status for VMs with masquerade binding).

## Catalog

- [Conclusion — root cause](#conclusion--root-cause)
- [Path](#path)
- [Targets](#targets)
- [Capture recipe](#capture-recipe)
- [1. Working — fedora104](#1-working--fedora104)
- [2. Non-working — fedora166](#2-non-working--fedora166)
  - [Root cause](#root-cause-verified-2026-07-30)
- [virtctl ssh](#virtctl-ssh)
  - [Laptop NIC — only the API](#laptop-nic--only-the-api-not-the-vm)
  - [Cluster side](#cluster-side-after-api-accepts-portforward)

## Path

```text
# virtctl ssh — laptop → API; backend dials VMI *status* IP (must be pod IP)
virtctl → API / portforward → dial STATUS_IP:22
        → [1] launcher eth0 (POD_IP:22) → DNAT   # only if STATUS_IP == POD_IP
        → [2] tap0 / guest (10.0.2.2:22) → sshd

# ssh/nc straight to the pod IP (always use pod IP, not status if wrong)
client → OVN → eth0 (POD_IP:22) → DNAT → tap0 / guest (10.0.2.2:22)
```

```text
eth0       <pod IP>/20     ← pre-DNAT (see pod / VMI IP)
k6t-eth0   10.0.2.1/24
tap0       master k6t-eth0 ← post-DNAT (see 10.0.2.2)
```

## Targets

| | fedora104 (working) | fedora166 (anomaly) |
| --- | --- | --- |
| Node / launcher | `d21-h31-000-r650` / `…-fedora104-74f96` | `e45-h07-000-r650` / `…-fedora166-4jcns` |
| Pod IP | `10.149.1.166` | `10.128.49.109` |
| VMI status IP | `10.149.1.166` | **`10.0.2.2`** (wrong) |
| Guest | `10.0.2.2/24` | `10.0.2.2/24` |

## Capture recipe

Two steps on the node (restricted PSS blocks ephemeral `kubectl debug` tcpdump):

```bash
NS=vm-migration
POD=<virt-launcher-…>
NODE=$(oc get pod -n "$NS" "$POD" -o jsonpath='{.spec.nodeName}')
CRIID=$(oc get pod -n "$NS" "$POD" -o jsonpath='{.status.containerStatuses[?(@.name=="compute")].containerID}' | sed 's|cri-o://||')

oc debug node/"$NODE"
chroot /host
PID=$(crictl inspect "$CRIID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["pid"])')

# Step 1 — enter netns, confirm interfaces
podman run --rm -it --cap-add=NET_RAW --cap-add=NET_ADMIN \
  --network=ns:/proc/${PID}/ns/net \
  quay.io/rh_ee_lguoqing/ocp-trace:4.22.0 bash
# inside:
ip a

# Step 2 — capture (virtctl ssh hits both):
tcpdump -ni eth0 tcp port 22 -vv   # dest = POD_IP
tcpdump -ni tap0 tcp port 22 -vv   # dest = 10.0.2.2
```

Probe from laptop:

```bash
virtctl ssh fedora@vmi/fedora104 -n vm-migration \
  --local-ssh-opts='-o StrictHostKeyChecking=no' \
  --local-ssh-opts='-o UserKnownHostsFile=/dev/null'
```

---

## 1. Working — `fedora104`

Manual verify from laptop `virtctl ssh` + ocp-trace in launcher netns (2026-07-30).  
Launcher `virt-launcher-fedora104-74f96`. Netns: `eth0=10.149.1.166/20`, `k6t-eth0=10.0.2.1/24`, `tap0` master `k6t-eth0`.

### `eth0` — pre-DNAT (`virtctl ssh`, ~20:24 UTC)

Dest = **pod IP** `10.149.1.166`. Source `10.130.0.182` = in-cluster portforward proxy.

```text
tcpdump: listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
20:24:43.202970 IP 10.130.0.182.39350 > 10.149.1.166.ssh: Flags [S], seq 2165729596, win 65280, options [mss 1360,sackOK,TS val 2007354036 ecr 0,nop,wscale 7], length 0
20:24:43.203289 IP 10.149.1.166.ssh > 10.130.0.182.39350: Flags [S.], seq 3769156340, ack 2165729597, win 64704, options [mss 1360,sackOK,TS val 1943808212 ecr 2007354036,nop,wscale 9], length 0
20:24:43.204524 IP 10.130.0.182.39350 > 10.149.1.166.ssh: Flags [.], seq 1, ack 1, win 510, options [nop,nop,TS val 2007354039 ecr 1943808212], length 0
20:24:43.210546 IP 10.149.1.166.ssh > 10.130.0.182.39350: Flags [P.], seq 1:23, ack 1, win 127, length 22: SSH: SSH-2.0-OpenSSH_10.0
20:24:43.210651 IP 10.130.0.182.39350 > 10.149.1.166.ssh: Flags [.], seq 1, ack 23, win 510, options [nop,nop,TS val 2007354046 ecr 1943808220], length 0
20:24:43.238658 IP 10.130.0.182.39350 > 10.149.1.166.ssh: Flags [P.], seq 1:23, ack 23, win 510, length 22: SSH: SSH-2.0-OpenSSH_10.2
20:24:43.238867 IP 10.149.1.166.ssh > 10.130.0.182.39350: Flags [.], seq 23, ack 23, win 127, options [nop,nop,TS val 1943808248 ecr 2007354073], length 0
20:24:43.243457 IP 10.149.1.166.ssh > 10.130.0.182.39350: Flags [P.], seq 23:1023, ack 23, win 127, length 1000
20:24:43.243577 IP 10.130.0.182.39350 > 10.149.1.166.ssh: Flags [P.], seq 23:1479, ack 23, win 510, length 1456
20:24:43.243646 IP 10.149.1.166.ssh > 10.130.0.182.39350: Flags [.], seq 1023, ack 1479, win 125, options [nop,nop,TS val 1943808253 ecr 2007354078], length 0
20:24:43.275677 IP 10.130.0.182.39350 > 10.149.1.166.ssh: Flags [P.], seq 1479:2711, ack 1023, win 503, length 1232
20:24:43.279881 IP 10.149.1.166.ssh > 10.130.0.182.39350: Flags [P.], seq 1023:2611, ack 2711, win 123, length 1588
20:24:43.280111 IP 10.130.0.182.39350 > 10.149.1.166.ssh: Flags [.], seq 2711, ack 2611, win 491, options [nop,nop,TS val 2007354115 ecr 1943808289], length 0
20:24:43.329781 IP 10.130.0.182.39350 > 10.149.1.166.ssh: Flags [P.], seq 2711:2795, ack 2611, win 491, length 84
20:24:43.329824 IP 10.130.0.182.39350 > 10.149.1.166.ssh: Flags [P.], seq 2795:2847, ack 2611, win 491, length 52
20:24:43.330134 IP 10.149.1.166.ssh > 10.130.0.182.39350: Flags [.], seq 2611, ack 2847, win 123, options [nop,nop,TS val 1943808339 ecr 2007354165], length 0
20:24:43.330246 IP 10.149.1.166.ssh > 10.130.0.182.39350: Flags [P.], seq 2611:2663, ack 2847, win 123, length 52
20:24:43.361126 IP 10.130.0.182.39350 > 10.149.1.166.ssh: Flags [P.], seq 2847:2915, ack 2663, win 491, length 68
20:24:43.362127 IP 10.149.1.166.ssh > 10.130.0.182.39350: Flags [P.], seq 2663:2959, ack 2915, win 123, length 296
20:24:43.399567 IP 10.130.0.182.39350 > 10.149.1.166.ssh: Flags [P.], seq 2915:3063, ack 2959, win 489, length 148
20:24:43.407684 IP 10.149.1.166.ssh > 10.130.0.182.39350: Flags [P.], seq 2959:3043, ack 3063, win 123, length 84
20:24:43.436510 IP 10.130.0.182.39350 > 10.149.1.166.ssh: Flags [P.], seq 3063:3211, ack 3043, win 489, length 148
```

### `tap0` — post-DNAT (`virtctl ssh`, ~20:26 UTC)

Dest = guest **`10.0.2.2`**. Source `10.128.1.21` = another portforward proxy session (same path shape as eth0 run).

```text
tcpdump: listening on tap0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
20:26:29.542119 IP 10.128.1.21.57830 > 10.0.2.2.ssh: Flags [S], seq 3027011424, win 65280, options [mss 1360,sackOK,TS val 1533971268 ecr 0,nop,wscale 7], length 0
20:26:29.542320 IP 10.0.2.2.ssh > 10.128.1.21.57830: Flags [S.], seq 4133127665, ack 3027011425, win 64704, options [mss 1360,sackOK,TS val 1774319314 ecr 1533971268,nop,wscale 9], length 0
20:26:29.543930 IP 10.128.1.21.57830 > 10.0.2.2.ssh: Flags [.], seq 1, ack 1, win 510, options [nop,nop,TS val 1533971270 ecr 1774319314], length 0
20:26:29.549530 IP 10.0.2.2.ssh > 10.128.1.21.57830: Flags [P.], seq 1:23, ack 1, win 127, length 22: SSH: SSH-2.0-OpenSSH_10.0
20:26:29.549680 IP 10.128.1.21.57830 > 10.0.2.2.ssh: Flags [.], seq 1, ack 23, win 510, options [nop,nop,TS val 1533971277 ecr 1774319321], length 0
20:26:29.575276 IP 10.128.1.21.57830 > 10.0.2.2.ssh: Flags [P.], seq 1:23, ack 23, win 510, length 22: SSH: SSH-2.0-OpenSSH_10.2
20:26:29.575458 IP 10.0.2.2.ssh > 10.128.1.21.57830: Flags [.], seq 23, ack 23, win 127, options [nop,nop,TS val 1774319347 ecr 1533971302], length 0
20:26:29.580042 IP 10.0.2.2.ssh > 10.128.1.21.57830: Flags [P.], seq 23:1023, ack 23, win 127, length 1000
20:26:29.580488 IP 10.128.1.21.57830 > 10.0.2.2.ssh: Flags [P.], seq 23:1479, ack 1023, win 503, length 1456
20:26:29.580529 IP 10.0.2.2.ssh > 10.128.1.21.57830: Flags [.], seq 1023, ack 1479, win 133, options [nop,nop,TS val 1774319352 ecr 1533971307], length 0
20:26:29.612885 IP 10.128.1.21.57830 > 10.0.2.2.ssh: Flags [P.], seq 1479:2711, ack 1023, win 503, length 1232
20:26:29.617341 IP 10.0.2.2.ssh > 10.128.1.21.57830: Flags [P.], seq 1023:2611, ack 2711, win 138, length 1588
20:26:29.617510 IP 10.128.1.21.57830 > 10.0.2.2.ssh: Flags [.], seq 2711, ack 2611, win 491, options [nop,nop,TS val 1533971344 ecr 1774319389], length 0
20:26:29.649996 IP 10.128.1.21.57830 > 10.0.2.2.ssh: Flags [P.], seq 2711:2847, ack 2611, win 491, length 136
20:26:29.650456 IP 10.0.2.2.ssh > 10.128.1.21.57830: Flags [P.], seq 2611:2663, ack 2847, win 144, length 52
20:26:29.689002 IP 10.128.1.21.57830 > 10.0.2.2.ssh: Flags [P.], seq 2847:2915, ack 2663, win 491, length 68
20:26:29.689803 IP 10.0.2.2.ssh > 10.128.1.21.57830: Flags [P.], seq 2663:2959, ack 2915, win 144, length 296
20:26:29.729617 IP 10.128.1.21.57830 > 10.0.2.2.ssh: Flags [P.], seq 2915:3063, ack 2959, win 489, length 148
20:26:29.737803 IP 10.0.2.2.ssh > 10.128.1.21.57830: Flags [P.], seq 2959:3043, ack 3063, win 147, length 84
20:26:29.767807 IP 10.128.1.21.57830 > 10.0.2.2.ssh: Flags [P.], seq 3063:3211, ack 3043, win 489, length 148
20:26:29.776058 IP 10.0.2.2.ssh > 10.128.1.21.57830: Flags [P.], seq 3043:3127, ack 3211, win 147, length 84
20:26:29.810550 IP 10.128.1.21.57830 > 10.0.2.2.ssh: Flags [P.], seq 3211:3359, ack 3127, win 489, length 148
20:26:29.818793 IP 10.0.2.2.ssh > 10.128.1.21.57830: Flags [P.], seq 3127:3211, ack 3359, win 147, length 84
20:26:29.852662 IP 10.128.1.21.57830 > 10.0.2.2.ssh: Flags [P.], seq 3359:3507, ack 3211, win 489, length 148
20:26:29.860994 IP 10.0.2.2.ssh > 10.128.1.21.57830: Flags [P.], seq 3211:3295, ack 3507, win 147, length 84
20:26:29.890212 IP 10.128.1.21.57830 > 10.0.2.2.ssh: Flags [P.], seq 3507:3655, ack 3295, win 489, length 148
20:26:29.898363 IP 10.0.2.2.ssh > 10.128.1.21.57830: Flags [P.], seq 3295:3379, ack 3655, win 147, length 84
20:26:29.927174 IP 10.128.1.21.57830 > 10.0.2.2.ssh: Flags [P.], seq 3655:3803, ack 3379, win 489, length 148
20:26:29.935313 IP 10.0.2.2.ssh > 10.128.1.21.57830: Flags [P.], seq 3379:3463, ack 3803, win 147, length 84
20:26:29.936503 IP 10.0.2.2.ssh > 10.128.1.21.57830: Flags [F.], seq 3463, ack 3803, win 147, options [nop,nop,TS val 1774319708 ecr 1533971654], length 0
20:26:29.936650 IP 10.128.1.21.57830 > 10.0.2.2.ssh: Flags [F.], seq 3803, ack 3464, win 489, options [nop,nop,TS val 1533971664 ecr 1774319707], length 0
20:26:29.936707 IP 10.0.2.2.ssh > 10.128.1.21.57830: Flags [.], seq 3464, ack 3804, win 147, options [nop,nop,TS val 1774319708 ecr 1533971664], length 0
```

| Interface | Dest on wire | Role |
| --------- | ------------ | ---- |
| `eth0` | `10.149.1.166:22` | Pre-DNAT — pod / VMI IP |
| `tap0` | `10.0.2.2:22` | Post-DNAT — guest |

**Verdict:** E2E healthy. `virtctl ssh` from the laptop lands on launcher **`eth0`** (pod IP) and, after DNAT, on **`tap0`** (`10.0.2.2`).

---

## 2. Non-working — `fedora166`

### Root cause (verified 2026-07-30)

`virtctl ssh` / `virtctl port-forward` dial whatever IP is on the **VMI status**. For fedora166 that is the guest masquerade address **`10.0.2.2`**, not the launcher pod IP **`10.128.49.109`**.

```bash
oc get vmi -n vm-migration fedora104 fedora166 -o wide
oc get pod -n vm-migration -l 'kubevirt.io/domain in (fedora104,fedora166)' \
  --field-selector=status.phase=Running -o wide
```

Live output:

```text
NAME        PHASE     IP             NODENAME
fedora104   Running   10.149.1.166   d21-h31-000-r650    ← status IP == pod IP
fedora166   Running   10.0.2.2       e45-h07-000-r650    ← status IP == guest masq (WRONG)

NAME                            POD_IP          NODE
virt-launcher-fedora104-74f96   10.149.1.166    d21-h31-000-r650
virt-launcher-fedora166-4jcns   10.128.49.109   e45-h07-000-r650
```

| | fedora104 (OK) | fedora166 (broken virtctl) |
| --- | --- | --- |
| VMI status IP | `10.149.1.166` | **`10.0.2.2`** |
| Launcher pod IP | `10.149.1.166` | `10.128.49.109` |
| Match? | yes | **no** |
| `virtctl port-forward … 22` | dials pod IP → works | `dial tcp 10.0.2.2:22: connect: connection timed out` |
| `nc` to pod IP | works | works (`10.128.49.109`) |

```bash
virtctl port-forward --stdio=true vmi/fedora166/vm-migration 22 </dev/null
# Internal error occurred: dialing VM: dial tcp 10.0.2.2:22: connect: connection timed out

virtctl ssh fedora@vmi/fedora166 -n vm-migration
# ProxyCommand → same dial of 10.0.2.2 → timeout; launcher tcpdump sees 0 packets
```

Guest having `10.0.2.2` on `enp1s0` is **normal** for masquerade. Publishing it as the VMI IP is what breaks portforward/ssh.

**Verdict:** NAT/launcher path is fine; failure is **wrong IP in VMI status** (`10.0.2.2` instead of pod `10.128.49.109`). Guest-agent fallback when pod IP is missing from status: [kubevirt#16421](https://github.com/kubevirt/kubevirt/issues/16421).

### Netns entry (2026-07-30 ~16:53 EDT)

Launcher `virt-launcher-fedora166-4jcns` on `e45-h07-000-r650`.  
Compute CRI-O ID: `ee1f7846c112a7f48a16ea5ab166e436b5f2461c8f095f13d153e3a26a982b6d`.

```bash
NS=vm-migration
POD=virt-launcher-fedora166-4jcns
NODE=$(oc get pod -n "$NS" "$POD" -o jsonpath='{.spec.nodeName}')
CRIID=$(oc get pod -n "$NS" "$POD" -o jsonpath='{.status.containerStatuses[?(@.name=="compute")].containerID}' | sed 's|cri-o://||')

oc debug node/"$NODE"
chroot /host
export CRIID=ee1f7846c112a7f48a16ea5ab166e436b5f2461c8f095f13d153e3a26a982b6d
PID=$(crictl inspect "$CRIID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["pid"])')

podman run --rm -it --cap-add=NET_RAW --cap-add=NET_ADMIN \
  --network=ns:/proc/${PID}/ns/net \
  quay.io/rh_ee_lguoqing/ocp-trace:4.22.0 bash
```

### Interfaces (`ip a` in launcher netns)

Same masquerade shape as working VM — only the pod IP differs:

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

| Interface | Address / role |
| --------- | -------------- |
| `eth0` | **`10.128.49.109/20`** — real pod IP (pre-DNAT target) |
| `k6t-eth0` | `10.0.2.1/24` — bridge to guest |
| `tap0` | master `k6t-eth0` — guest path (post-DNAT `10.0.2.2`) |

### Probe from a node + `tcpdump -ni any` (2026-07-30 ~20:58 UTC)

Probe (from `oc debug node/f25-h03-000-r660` — any node that can reach the pod network):

```bash
nc -vz 10.128.49.109 22
# Ncat: Connected to 10.128.49.109:22.
```

Capture in launcher netns with **`tcpdump -ni any`** so one dump shows DNAT across all three ifaces:

```bash
tcpdump -ni any tcp port 22 -vv
```

```text
20:58:06.497110 eth0     In   10.147.48.2.36120 > 10.128.49.109.ssh: Flags [S]
20:58:06.497134 k6t-eth0 Out  10.147.48.2.36120 > 10.0.2.2.ssh:       Flags [S]
20:58:06.497140 tap0     Out  10.147.48.2.36120 > 10.0.2.2.ssh:       Flags [S]
20:58:06.497337 tap0     P    10.0.2.2.ssh > 10.147.48.2.36120:       Flags [S.]
20:58:06.497337 k6t-eth0 In   10.0.2.2.ssh > 10.147.48.2.36120:       Flags [S.]
20:58:06.497358 eth0     Out  10.128.49.109.ssh > 10.147.48.2.36120:  Flags [S.]
20:58:06.499410 eth0     In   10.147.48.2.36120 > 10.128.49.109.ssh: Flags [.]
20:58:06.499422 k6t-eth0 Out  10.147.48.2.36120 > 10.0.2.2.ssh:       Flags [.]
20:58:06.499426 tap0     Out  10.147.48.2.36120 > 10.0.2.2.ssh:       Flags [.]
20:58:06.499464 eth0     In   10.147.48.2.36120 > 10.128.49.109.ssh: Flags [F.]
… (ACK / FIN mirrored on k6t-eth0 + tap0 with dest 10.0.2.2)
20:58:06.508072 tap0     P    10.0.2.2.ssh > 10.147.48.2.36120:       Flags [P.], length 22: SSH: SSH-2.0-OpenSSH_10.0
20:58:06.508072 k6t-eth0 In   10.0.2.2.ssh > 10.147.48.2.36120:       Flags [P.], length 22: SSH: SSH-2.0-OpenSSH_10.0
20:58:06.508089 eth0     Out  10.128.49.109.ssh > 10.147.48.2.36120:  Flags [P.], length 22: SSH: SSH-2.0-OpenSSH_10.0
20:58:06.508355 eth0     In   10.147.48.2.36120 > 10.128.49.109.ssh: Flags [R]   # nc -vz close
```

DNAT in one glance (same TCP seq on the SYN):

| Hop | IF | Dest on wire |
| --- | -- | ------------ |
| 1 | `eth0` In | **`10.128.49.109:22`** (pod IP) |
| 2 | `k6t-eth0` Out / `tap0` Out | **`10.0.2.2:22`** (guest) |
| 3 | reply `tap0` → `k6t-eth0` → `eth0` Out | src rewritten back to **`10.128.49.109`** |

**Wire path OK** when probing pod IP. Contrast with `virtctl` which dials status `10.0.2.2` and never reaches the launcher.

### `virtctl ssh` evidence (2026-07-30 ~21:00 UTC)

```text
Executing proxy command: exec virtctl port-forward --stdio=true vmi/fedora166/vm-migration 22
Internal error occurred: dialing VM: dial tcp 10.0.2.2:22: connect: connection timed out
```

Launcher `tcpdump -ni any tcp port 22` during that attempt: **0 packets**.

---

## virtctl ssh

### Laptop NIC — only the API (not the VM)

`virtctl ssh` runs local OpenSSH with:

```text
ProxyCommand virtctl port-forward --stdio=true vmi/<name>/<ns> 22
```

Packets leaving the laptop are **TLS to the OpenShift API** (`:6443`), not TCP/22 to the VM and not directly to a `virt-api` pod IP.

Live capture on workstation `rh` during `virtctl ssh` (2026-07-30 ~17:04):

```bash
sudo tcpdump -i any tcp port 6443
```

```text
tun0  Out  rh.60150 > 10.1.48.3.sun-sr-https: Flags [S]     # API :6443
tun0  In   10.1.48.3.sun-sr-https > rh.60150: Flags [S.]
… TLS / websocket to kube-apiserver
```

| Where | What you see |
| ----- | ------------ |
| Laptop `tun0` | `rh` ↔ **`10.1.48.3:6443`** (API via VPN) |
| Not on laptop | `*:22`, pod IP, or guest `10.0.2.2` |

kube-apiserver then invokes the VMI **portforward** subresource (served by OpenShift Virtualization / virt-api behind the API). From the laptop you only ever see the API hop.

### Cluster side (after API accepts portforward)

Backend dials the **VMI status IP**:

| VMI | Status IP | Result |
| --- | --------- | ------ |
| fedora104 | `10.149.1.166` (= pod IP) | `eth0` / `tap0` see SSH; portforward works |
| fedora166 | `10.0.2.2` (≠ pod `10.128.49.109`) | dial timeout; **0** launcher packets |

API path to reproduce:

```bash
# same subresource virtctl uses
${API}/apis/subresources.kubevirt.io/v1/namespaces/vm-migration/virtualmachineinstances/fedora166/portforward/22
# or: virtctl port-forward --stdio=true vmi/fedora166/vm-migration 22
```
