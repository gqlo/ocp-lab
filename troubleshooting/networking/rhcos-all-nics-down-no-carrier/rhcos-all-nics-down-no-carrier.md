# RHCOS: all NICs down, boot a shell, prove there is no link

**Last Updated:** 2026-11-20

Scale Lab Jetlag worker `d36-h04-000-r660` (cloud29 / `vlan615`, `public_vlan: true`) booted RHCOS with no usable address. The console repeated `Failed to find a suitable node IP`. SSH was impossible. The BMC virtual console was the only path in. After a root shell on the installed system, the public-VLAN port had no carrier while the lab port on the same server did.

## Catalog

- [Lesson (short)](#lesson-short)
- [Environment](#environment)
- [Symptoms](#symptoms)
- [Get a shell when every NIC is down](#get-a-shell-when-every-nic-is-down)
- [How the missing link was established](#how-the-missing-link-was-established)
- [Link detected and LOWER_UP](#link-detected-and-lower_up)
- [What this does not prove](#what-this-does-not-prove)
- [References](#references)

---

## Lesson (short)

`nodeip-configuration` logs `Failed to find a suitable node IP` when the node has no address that routes to the API and ingress VIPs [[1]](#ref-1) [[2]](#ref-2). On this host that was a consequence, not the fault. `ethtool` reported `Link detected: no` on the public-VLAN port `eno12409np1` and `Link detected: yes` on the lab port `ens2f0np0`. The word `NO-CARRIER` was printed for both. The flag that matched `ethtool` was `LOWER_UP`, which only the lab port had [[7]](#ref-7).

A MachineConfig `core` password cannot be delivered while the node has no route to the API [[4]](#ref-4). On this RHCOS 10.2 boot, adding `single` to the GRUB `linux` line opened a root shell on the installed system with no password prompt. That is the shell the link tests below were run from.

---

## Environment

| Item | Value |
|------|--------|
| Lab | Scale Lab (RDU2), cloud29, cluster `vlan615` |
| Node | `d36-h04-000-r660` (worker) |
| OS | RHCOS 10.2.20261102-1, kernel `6.12.0-211.73.1.el10_2` |
| Machine network | `10.1.62.0/25`, gateway `10.1.62.126`, DNS `10.1.62.1` |
| VIPs in the log | `10.1.62.3`, `10.1.62.4` |
| Expected node IP | `10.1.62.12/25` |
| Public-VLAN MAC | `04:32:01:aa:e8:01` → `eno12409np1` |
| Lab MAC | `04:32:01:aa:e8:00` → `eno12399np0` |
| Lab port with link | `ens2f0np0` |
| Access | iDRAC virtual console. No SSH. |

Inventory names the control-plane interface `eth0`. On this boot `eth0` did not exist. The MAC above was `eno12409np1`. The name mismatch did not matter: that port had no carrier, so no address could appear on it.

---

## Symptoms

- Console and journal repeat:

  ```text
  level=error msg="Failed to find a suitable node IP"
  ```

  The lines just above only inspect `127.0.0.1/8`, `::1/128`, and `fe80::` link-local addresses, then "Checking whether address … contains VIP 10.1.62.3" and `10.1.62.4`.

- `ip -br link` shows every NIC `DOWN`. Only `lo` has an address.

- `ssh core@10.1.62.12` cannot work. There is no address to connect to.

---

## Get a shell when every NIC is down

RHCOS `core` has an SSH key and no password. The key is useless without an address. A MachineConfig password is written by `machine-config-daemon` on the node, which has to pull it from the API [[4]](#ref-4). That pull cannot happen while every NIC is down.

### 1. Open the BMC console

iDRAC → Dashboard → Virtual Console → Launch Virtual Console. HTML5, not eHTML5. The black pane is the machine screen. **Boot**, **Power**, **Virtual Media**, and **Keyboard** are the useful menus. **Chat** is not a login.

### 2. Stop at GRUB

**Power** → Reset. At the GRUB menu press `e`.

This node's `linux` line had no `console=` argument, so there was nothing to delete. Some Red Hat procedures say to drop `console=ttyS0,115200n8` so output stays on the virtual console [[5]](#ref-5). Skip that step when the parameter is absent.

### 3. Add `single`

Append `single` at the end of the `linux` line, after the last token (`psi=1` here) and before `initrd`:

```text
psi=1 single
```

Press `Ctrl+x`.

On this node that booted the installed system straight to a root shell. The prompt was `[root@d36-h04-000-r660 ~]#`. There was no password prompt. `ip` and `ethtool` from that shell are the installed OS, so the link test below is valid [[5]](#ref-5).

---

## How the missing link was established

The order matters. Each step throws out one explanation.

1. **The OpenShift error means "no address in the VIP subnet."** `nodeip-configuration` looks for a local address that routes to the virtual IPs it was given. If it finds none, it logs `Failed to find a suitable node IP` and retries [[1]](#ref-1). Red Hat documents the same message when the primary interface is down and has no IP, with the console as the only access [[2]](#ref-2). The log was checking VIPs `10.1.62.3` and `10.1.62.4` and only saw loopback and link-local. So the next question was why `10.1.62.12/25` was missing, not why keepalived itself was broken.

2. **Identify the port that should hold that address.** Inventory maps `d36-h04-000-r660` to `10.1.62.12/25` on MAC `04:32:01:aa:e8:01`. `ip -br link` showed that MAC on `eno12409np1`. `ip link show eth0` returned `Device "eth0" does not exist.` The kernel name and the inventory name differed. That was noted and set aside until the carrier test, because a rename cannot create a link.

3. **Bring that port up and read the flags.** After `ip link set eno12409np1 up`:

   ```text
   eno12409np1  DOWN  04:32:01:aa:e8:01 <NO-CARRIER,BROADCAST,MULTICAST,UP>
   ```

   `UP` means the interface is administratively up [[3]](#ref-3). This line has `NO-CARRIER` and no `LOWER_UP`.

4. **Compare every port, then ask `ethtool`.** Bringing the rest up:

   ```text
   eno12399np0  DOWN  04:32:01:aa:e8:00 <NO-CARRIER,BROADCAST,MULTICAST,UP>
   eno12409np1  DOWN  04:32:01:aa:e8:01 <NO-CARRIER,BROADCAST,MULTICAST,UP>
   ens2f0np0    DOWN  a0:88:c2:d5:0c:12 <NO-CARRIER,BROADCAST,MULTICAST,UP,LOWER_UP>
   ens1f0       DOWN  b4:83:51:10:77:46 <NO-CARRIER,BROADCAST,MULTICAST,UP>
   ens2f1np1    DOWN  a0:88:c2:d5:0c:13 <NO-CARRIER,BROADCAST,MULTICAST,UP,LOWER_UP>
   ens1f1       DOWN  b4:83:51:10:77:47 <NO-CARRIER,BROADCAST,MULTICAST,UP>
   ```

   ```bash
   ethtool ens2f0np0 | grep 'Link detected'
   ethtool eno12409np1 | grep 'Link detected'
   ```

   ```text
   ens2f0np0:    Link detected: yes
   eno12409np1:  Link detected: no
   ```

5. **Stop at Layer 1 for the port with `Link detected: no`.** The kernel diagnostic says a missing link is a cable fault or no connection at the link partner, and to look at VLANs only after the link is up [[3]](#ref-3). `eno12409np1` never got a link, so the node IP, the gateway `10.1.62.126`, and the `eth0` name were not tested. There was no interface on which to put `10.1.62.12/25`.

---

## Link detected and LOWER_UP

`ip -br link` prints three different facts. The second column is the operational state. It said `DOWN` on every NIC here, including `ens2f0np0`, so that column did not show which ports had a cable.

| Token | Meaning | Source |
|-------|---------|--------|
| `UP` | Administrator enabled the port | Layer 1 diagnostic [[3]](#ref-3) |
| `LOWER_UP` | Driver has called `netif_carrier_on()`. The lower layer sees carrier. | Operational states [[7]](#ref-7) |
| no `LOWER_UP` | Driver has called `netif_carrier_off()`. The kernel's own "no carrier" bit is the absence of `LOWER_UP`. | Operational states [[7]](#ref-7) |
| the word `NO-CARRIER` | Printed in the same bracket. The Layer 1 page defines this word as "administratively up, no physical link" and never mentions `LOWER_UP`. | Layer 1 diagnostic [[3]](#ref-3) |

On this host the word `NO-CARRIER` was present on every NIC, including `ens2f0np0`, which also had `LOWER_UP`. The Layer 1 page's example is `<NO-CARRIER,BROADCAST,MULTICAST,UP>` with no `LOWER_UP`, so that page alone cannot separate these two ports. Its next step is `ethtool` [[3]](#ref-3).

`ethtool` reads the PHY:

- `Link detected: yes` on `ens2f0np0`. That matched `LOWER_UP`. The lab cable is connected. Red Hat describes `LOWER_UP` the same way: the cable is in and the physical link is up [[6]](#ref-6).
- `Link detected: no` on `eno12409np1`. That matched "no `LOWER_UP`". Red Hat's case for `Link detected: no` with `<NO-CARRIER,...,UP>` and no `LOWER_UP` is a cable that is not connected [[6]](#ref-6).

`ens2f1np1` also had `LOWER_UP`. `eno12399np0`, `ens1f0`, and `ens1f1` did not. The public-VLAN address belongs on `eno12409np1`, the port with `Link detected: no`.

---

## What this does not prove

`Link detected: no` does not separate an unplugged cable from a switch port that is shut. Both are "no connection at the link partner" [[3]](#ref-3). The host cannot see the switch config. The lab has to check the cable and the switch port for MAC `04:32:01:aa:e8:01`.

---

## References

1. <a id="ref-1"></a>[OpenShift `node-ip` — `Failed to find a suitable node IP`](https://github.com/openshift/baremetal-runtimecfg/blob/master/cmd/runtimecfg/node-ip.go) — logs that error when no local address routes to the given virtual IPs, then retries.
2. <a id="ref-2"></a>[Node addition fails with "Failed to find a suitable node IP" due to network interface not activated](https://access.redhat.com/solutions/7142167) — same error when the primary NIC is down and has no address; console is the only access.
3. <a id="ref-3"></a>[Diagnostic Concept for Investigating Twisted Pair Ethernet Variants at OSI Layer 1](https://docs.kernel.org/networking/diagnostic/twisted_pair_layer1_diagnostics.html) — `UP` is administrative; `NO-CARRIER` means no physical link. VLAN checks come after the link is detected.
4. <a id="ref-4"></a>[Changing the core user password for node access](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/machine_configuration/machine-configs-configure#core-user-password_machine-configs-configure) — Machine Config Operator writes the hash into `/etc/shadow`. The password works on the BMC console, not over SSH, and the node must be able to receive the config.
5. <a id="ref-5"></a>[How to start Red Hat CoreOS (RHCOS) in emergency mode in OpenShift 4](https://access.redhat.com/solutions/5500131) — from GRUB, drop an unused serial `console=` argument and add `single` when SSH is unreachable and the console has no password.
6. <a id="ref-6"></a>["No link detected" from ethtool and mii-tool](https://access.redhat.com/solutions/1128183) — `Link detected: no` with `<NO-CARRIER,...,UP>` and no `LOWER_UP` means the cable is not connected. `LOWER_UP` means the physical link is up.
7. <a id="ref-7"></a>[Operational States](https://docs.kernel.org/networking/operstates.html) — `IFF_LOWER_UP` means the driver called `netif_carrier_on()`. `__LINK_STATE_NOCARRIER` is the absence of `IFF_LOWER_UP`.
