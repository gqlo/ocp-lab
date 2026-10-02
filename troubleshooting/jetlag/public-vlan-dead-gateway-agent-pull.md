# Jetlag `wait-hosts-discovered`: public VLAN gateway dead, agent cannot pull quay.io

**Last Updated:** 2026-10-02

Lab note from a Scale Lab Jetlag MNO deploy (`public_vlan: true`, cloud29 /
`vlan606` on Dell r670). Nodes booted discovery and got CP IPs, but Assisted
Installer stayed at **0 hosts** until the default gateway was pointed at the
bastion instead of the QUADS-published VLAN router. QUADS later confirmed a
lab-side network automation bug on early R670 assignments.

## Catalog

- [Lesson (short)](#lesson-short)
- [Environment](#environment)
- [Symptoms](#symptoms)
- [Root cause](#root-cause)
- [Evidence](#evidence)
- [Remediation](#remediation)
  - [Prefer: QUADS / lab net](#prefer-quads--lab-net)
  - [Immediate (one node) — workaround while waiting](#immediate-one-node--workaround-while-waiting)
  - [Permanent (inventory) — workaround if QUADS fix is delayed](#permanent-inventory--workaround-if-quads-fix-is-delayed)
- [Verify](#verify)
- [Related issues seen in the same deploy](#related-issues-seen-in-the-same-deploy)
- [Related](#related)

---

## Lesson (short)

With `public_vlan: true`, Jetlag sets node `gateway=` from **QUADS**
`vlan.gateway` (often `.254`). DNS stays on the bastion (`.1`).

If that QUADS gateway is **unreachable** on the wire (here: early R670
assignment missing vlan606 on the last interface — QUADS automation bug, since
fixed), discovery nodes have **no egress**. `agent.service` cannot pull
`quay.io/edge-infrastructure/assisted-installer-agent`, so hosts never register
and `Wait up to 40 min for nodes to be discovered` fails / retries forever.

**Prefer** asking QUADS / lab net to re-apply the public VLAN assignment. As a
workaround, keep `public_vlan: true` and override gateway to the **bastion**
(`nthhost(1)`, e.g. `10.1.55.1`) when bastion NAT works. **Do not** flip
`public_vlan` to `false` only to fix this.

---

## Environment

| Item | Value |
|------|--------|
| Lab | Scale Lab (RDU2) |
| Tooling | [Jetlag](https://github.com/redhat-performance/jetlag) `mno-deploy.yml` |
| Cloud | `cloud29` / cluster `vlan606` |
| `public_vlan` | `true` |
| Control-plane CIDR | `10.1.55.0/24` |
| Bastion | `f24-h03-000-r670` — lab `10.1.91.48`, CP `10.1.55.1` |
| Example node | `f24-h04-000-r670` — CP `10.1.55.5` |
| Hardware | Dell r670 |

---

## Symptoms

- Ansible stuck or failed on:

  ```text
  TASK [wait-hosts-discovered : Wait up to 40 min for nodes to be discovered]
  ```

- Assisted API / UI shows **0 hosts** (or far fewer than inventory):

  ```bash
  curl -s http://localhost:8090/api/assisted-install/v2/clusters \
    | jq '.[] | {name, status, hosts:(.hosts|length)}'
  ```

- Node is reachable on CP IP (`ping 10.1.55.5`) and discovery OS is up
  (`ssh core@10.1.55.5` with the key baked from the Ansible **controller**).

- On the node, `journalctl -u agent` shows repeated pull failures:

  ```text
  Trying to pull quay.io/edge-infrastructure/assisted-installer-agent:v2.54.0...
  dial tcp ...:443: connect: ...
  Pull failed for quay.io/edge-infrastructure/assisted-installer-agent:...
  ```

---

## Root cause

### Lab / QUADS (confirmed)

This cloud was one of the **first early R670 workloads** in the lab (first time
in service; assignment around **2026-09-27**). A bug in the **QUADS network
automation** (since fixed) left **VLAN configs missing on the last interface**
that handles the optional routable public VLAN (**vlan606**). Without that
switch-side config, the published VLAN router (`.254`) was not present on the
wire even though QUADS still advertised `vlan.gateway`.

QUADS resolved the switch-side assignment for this cloud. Other early R670
assignments may still need an automation pass-over if they hit the same gap.

### How it showed up in Jetlag

1. **`create-inventory` + `public_vlan`** loads addressing from QUADS and sets:

   ```yaml
   controlplane_network_gateway: "{{ quads_assignment.json.vlan.gateway }}"
   ```

   That becomes `gateway=` in `ansible/inventory/<cloud>.local` (controlplane
   and worker groups).

2. For this cloud, QUADS returned **`10.1.55.254`**. Nodes got:

   ```text
   default via 10.1.55.254 dev <cp-iface>
   ```

3. **`10.1.55.254` did not answer ARP** (“Destination Host Unreachable”) —
   consistent with the missing vlan606 config on the last interface. Bastion
   **`10.1.55.1` was reachable**, and bastion NAT (`ip_forward` + `MASQUERADE`
   on `bastion_lab_interface`) could reach the internet.

4. Without a working default route, nodes could not reach quay.io → agent image
   never pulled → no Assisted registration.

Default **without** `public_vlan` would have been bastion as gateway
(`nthhost(1)`). Public VLAN intentionally prefers the lab VLAN router from
QUADS; here the metadata pointed at a router that was absent until QUADS fixed
the assignment.

---

## Evidence

On discovery node (`core@10.1.55.5`):

```bash
ip route
# default via 10.1.55.254 ...

ping -c2 10.1.55.1     # OK (bastion)
ping -c2 10.1.55.254   # Destination Host Unreachable
ping -c2 8.8.8.8       # Destination Host Unreachable
```

After pointing default route at the bastion:

```bash
sudo ip route replace default via 10.1.55.1 dev eno16805np1
ping -c2 8.8.8.8       # OK
# agent then pulls quay.io/.../assisted-installer-agent and registers
```

Inventory source (generated):

```text
# [controlplane:vars] / [worker:vars]
gateway=10.1.55.254    # from QUADS vlan.gateway — broken on this cloud
dns1=10.1.55.1         # bastion — fine
```

Jetlag code path:

- `ansible/roles/create-inventory/tasks/main.yml` — Public VLAN block sets
  `controlplane_network_gateway` from `quads_assignment.json.vlan.gateway`
- `ansible/roles/create-inventory/templates/inventory-mno.j2` —
  `gateway={{ controlplane_network_gateway }}`
- `ansible/roles/bastion-network/tasks/main.yml` — NAT masquerade out
  `bastion_lab_interface`

---

## Remediation

### Prefer: QUADS / lab net

Ask QUADS to re-apply the public VLAN (vlan606) assignment on the last
interface. That restores the published `.254` gateway on the wire. Early R670
clouds from ~2026-09-27 may still need this pass-over if automation left them
half-configured.

### Immediate (one node) — workaround while waiting

```bash
# On discovery node — temporary until reboot / new ISO / QUADS fix
sudo ip route replace default via 10.1.55.1 dev <cp-interface>
sudo systemctl restart agent   # if still in pull backoff
sudo journalctl -u agent -f
```

Confirm bastion NAT:

```bash
# On bastion
sysctl net.ipv4.ip_forward
iptables -t nat -L POSTROUTING -n -v | grep -i masquerade
curl -I --max-time 10 https://quay.io/v2/
```

### Permanent (inventory) — workaround if QUADS fix is delayed

Keep `public_vlan: true`. Change generated inventory gateways to the bastion:

```text
# ansible/inventory/cloud29.local — both controlplane and worker :vars
gateway=10.1.55.1
```

**Note:** Re-running `create-inventory` with `public_vlan: true` will set
`controlplane_network_gateway` from QUADS again and can overwrite `.1` with
`.254`. After regenerate, re-apply the override (or set an explicit override
that wins for your workflow).

Then recreate Assisted infra-env / discovery ISO and re-boot nodes so nmstate
embeds the new gateway (editing inventory alone does not fix already-booted
discovery hosts).

**Do not** set `public_vlan: false` solely for this issue — that switches you
to private CP defaults (different CIDR/topology), not a gateway-only fix.

---

## Verify

```bash
# Bastion — host count should climb toward inventory size (e.g. 3+10=13)
curl -s http://localhost:8090/api/assisted-install/v2/clusters \
  | jq '.[] | {name, status, hosts:(.hosts|length)}'

# Node — agent running next-step-runner against bastion :8090
sudo journalctl -u agent -b --no-pager | tail -40
```

Successful agent log includes pull of
`assisted-installer-agent:v2.54.0` and `next_step_runner --url http://<bastion>:8090`.

---

## Related issues seen in the same deploy

These were **not** the quay pull root cause, but showed up while debugging:

| Issue | Note |
|-------|------|
| Ansible `lookup('file', ssh_public_key_file)` | Reads key on **controller** (laptop), not bastion. `ssh core@` from bastion needs that private key (`-A` / `-i` / `-J`). |
| iDRAC10 Virtual Media | ISO may be `Inserted` while boot order is PXE-first; Redfish `BootSourceOverride*` / `BootOrder` often read-only — use racadm `FirstBootDevice=VCD-DVD` + `BootOnce`. |
| Duplicate bastion CP IP | Same `10.1.55.1/24` on two NICs (e.g. `eno16805np1` + leftover `eno16605np1`) — remove the duplicate; keep the iface named in `bastion_controlplane_interface`. |

---

## Related

- [Jetlag `mno-deploy` fails on Dell r670: Invalid Command `VirtualMediaInsert`](./idrac10-virtualmediainsert-community-general.md)
- Jetlag upstream troubleshooting: “Wait up to 40 min for nodes to be discovered” — agent pull / DNS / NAT
- `ansible/roles/create-inventory/tasks/main.yml` (Public VLAN autoconfiguration)
- `ansible/roles/wait-hosts-discovered/tasks/main.yml`
