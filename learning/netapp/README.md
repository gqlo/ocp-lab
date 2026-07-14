# NetApp NFS storage network

OCP workers reach NetApp NFS on the storage subnet (`10.200.0.0/24`) via a
second NIC (`ens2f0np0`, Network 3). The OVN machine-network uplinks
(`eno2np1` on r640, `eno12409np1` on r650) must stay unchanged.

The storage network is **routeless**: flat `/24`, no gateway, no DHCP from the
network team. Workers and storage talk on-link within `10.200.0.0/24`.

## IP allocation

| Address        | Role                          |
|----------------|-------------------------------|
| `10.200.0.10`  | NetApp NFS LIF (fixed)        |
| `10.200.0.2`   | Bastion storage NIC (example) |
| `10.200.0.11+` | OCP worker `ens2f0np0` clients  |

## Setup order

1. Network team: VLAN re-membership of worker `ens2f0np0` MACs onto the storage VLAN.
2. Bastion: static IP on storage NIC (this doc, step 1).
3. Bastion: optional dnsmasq DHCP for workers (step 2).
4. Cluster: NNCP on workers — `dhcp: true` or static per node.
5. Validate: `ping` and `showmount` to `10.200.0.10`.

---

## Step 1 — Bastion static IP on storage NIC

The bastion must have a NIC on the **same storage VLAN** as worker `ens2f0np0`.
Assign a fixed address before running a DHCP server on the bastion.

```bash
# Find the storage interface name
ip -br link

# Set variables (edit STORAGE_IF)
STORAGE_IF=ens2f0np0        # storage VLAN NIC
BASTION_IP=10.200.0.2       # any free IP except 10.200.0.10 (NetApp)

# Create NM connection (routeless: no gateway, no default route)
sudo nmcli con add type ethernet ifname "$STORAGE_IF" con-name netapp-storage \
  ipv4.method manual \
  ipv4.addresses ${BASTION_IP}/24 \
  ipv4.gateway "" \
  ipv4.never-default yes \
  ipv6.method ignore \
  connection.autoconnect yes

# Bring it up
sudo nmcli con up netapp-storage
```

Verify:

```bash
ip -br addr show "$STORAGE_IF"
ip route show dev "$STORAGE_IF"
ping -c 3 10.200.0.10    # NetApp LIF, if reachable
```

If a `netapp-storage` connection already exists, modify instead of adding:

```bash
sudo nmcli con mod netapp-storage \
  ipv4.method manual \
  ipv4.addresses ${BASTION_IP}/24 \
  ipv4.gateway "" \
  ipv4.never-default yes
sudo nmcli con up netapp-storage
```

Temporary test only (not persistent across reboot):

```bash
sudo ip link set "$STORAGE_IF" up
sudo ip addr add ${BASTION_IP}/24 dev "$STORAGE_IF"
```

---

## Step 2 — Bastion DHCP (optional)

If using bastion dnsmasq instead of static NNCP per worker, install and configure
after step 1. See `bastion-dhcp-dnsmasq.conf.example`.

Worker NNCP for DHCP mode: `storage-dhcp-nncp.yaml`.

---

## Step 3 — Worker addressing (choose one)

**Option A — DHCP from bastion:** one NNCP with `dhcp: true` on `ens2f0np0`.

**Option B — Static per node:** one NNCP per worker with a unique IP from
`10.200.0.11`–`10.200.0.254`. Example: `storage-e26-h15-000-r640-nncp.yaml`.

Apply all static NNCPs:

```bash
oc apply -f storage-e26-h15-000-r640-nncp.yaml \
         -f storage-e26-h17-000-r640-nncp.yaml \
         -f storage-e29-h01-000-r640-nncp.yaml \
         -f storage-e29-h03-000-r640-nncp.yaml \
         -f storage-e29-h06-000-r640-nncp.yaml \
         -f storage-e34-h01-000-r650-nncp.yaml \
         -f storage-e45-h11-000-r650-nncp.yaml \
         -f storage-e45-h13-000-r650-nncp.yaml \
         -f storage-e45-h14-000-r650-nncp.yaml
```

---

## Validation

On a worker (host namespace):

```bash
ip -br addr show ens2f0np0
ping -c 3 10.200.0.10
showmount -e 10.200.0.10
```

Check `ens2f0np0` exists on all nodes (does not touch OVN uplink):

```bash
../../../vstorm/monitoring/scripts/check-ocp-node-nic.sh ens2f0np0
```

## Node → IP mapping (static NNCPs)

| Node | IP |
|------|-----|
| e26-h15-000-r640 | 10.200.0.20 |
| e26-h17-000-r640 | 10.200.0.21 |
| e29-h01-000-r640 | 10.200.0.22 |
| e29-h03-000-r640 | 10.200.0.23 |
| e29-h06-000-r640 | 10.200.0.24 |
| e34-h01-000-r650 | 10.200.0.25 |
| e45-h11-000-r650 | 10.200.0.26 |
| e45-h13-000-r650 | 10.200.0.27 |
| e45-h14-000-r650 | 10.200.0.28 |
