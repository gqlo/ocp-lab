# Jetlag `mno-deploy` fails on Dell r670: Invalid Command `VirtualMediaInsert`

**Last Updated:** 2026-09-28

Lab note from a Scale Lab Jetlag MNO deploy on Dell **r670** (iDRAC10).
`boot-iso` could probe Virtual Media over Redfish, but
`community.general.redfish_command` rejected `VirtualMediaInsert` until the
Ansible control-node venv was rebuilt on a modern Python with a current
`community.general` collection.

## Catalog

- [Lesson (short)](#lesson-short)
- [Environment](#environment)
- [Symptoms](#symptoms)
- [Red herring: IPMI power off](#red-herring-ipmi-power-off)
- [Root cause](#root-cause)
- [Evidence](#evidence)
- [Fix](#fix)
- [Verify](#verify)
- [Related](#related)

---

## Lesson (short)

Jetlag’s Dell **iDRAC10+** path (r670 and similar) mounts the discovery ISO with:

```text
category: Systems
command: VirtualMediaInsert
```

That only works with a **recent `community.general`**. An old Jetlag venv on
**Python 3.6** + **`community.general 3.8.3`** only allows power/boot commands
under `Systems`, so Insert fails immediately (retries do not help).

Rebuild `.ansible` with **Python ≥ 3.9** and install a current
`community.general` (≥ 9), then re-run `mno-deploy`.

---

## Environment

| Item | Value |
|------|--------|
| Lab | Scale Lab |
| Tooling | [Jetlag](https://github.com/redhat-performance/jetlag) (`mno-deploy.yml` → `boot-iso`) |
| Hardware | Dell r670 (iDRAC10+) |
| Example nodes | `f24-h03-000-r670`, `f24-h04-000-r670` |
| Control host (bastion / runner) | e.g. `n42-h01-b02-mx750c` |
| Broken env | Python **3.6.8**, `community.general` **3.8.3** under `/root/jetlag/.ansible` |
| Working env | Python **≥ 3.9**, `community.general` **≥ 9** |

Jetlag role reference: `ansible/roles/boot-iso/tasks/dell.yml` (iDRAC generation
probe → Systems VirtualMedia for iDRAC10+).

---

## Symptoms

During `ansible-playbook … ansible/mno-deploy.yml`, `boot-iso` reaches Insert
and retries ~10× (30s delay), then fails:

```text
TASK [boot-iso : DELL - Insert Virtual Media for f24-h04-000-r670]
FAILED - RETRYING: DELL - Insert Virtual Media for f24-h04-000-r670 (10 retries left).
...
fatal: [...]: FAILED! => {
  "attempts": 10,
  "changed": false,
  "msg": "Invalid Command 'VirtualMediaInsert'. Valid Commands = ['PowerOn', 'PowerForceOff', 'PowerForceRestart', 'PowerGracefulRestart', 'PowerGracefulShutdown', 'PowerReboot', 'SetOneTimeBoot', 'EnableContinuousBootOverride', 'DisableBootOverride']"
}
```

Typical preceding tasks for the same host:

| Task | Result | Meaning |
|------|--------|---------|
| Dell - Power down machine… | `FAILED` then `...ignoring` | See [red herring](#red-herring-ipmi-power-off) |
| Dell - Wait for power down… | `skipping` | Skipped because power-off “failed” |
| Dell - Check for Virtual Media… | `ok` | Redfish VM endpoint is reachable |
| Dell - Eject any CD Virtual Media… | `skipping` | Nothing mounted yet |
| DELL - Insert Virtual Media… | **fatal** after retries | Collection rejects the command |

Also common when listing collections on the broken venv:

```text
Could not find community.general>=9.0.0.

Collection        Version
----------------- -------
community.general 3.8.3
```

Ansible may warn that the controller is on Python 3.6 (unsupported for modern
ansible-core / collections).

---

## Red herring: IPMI power off

```text
TASK [boot-iso : Dell - Power down machine prior to booting iso for f24-h04-000-r670]
fatal: [...]: FAILED! => {
  "stderr": "Set Chassis Power Control to Down/Off failed: Command not supported in present state",
  ...
}
...ignoring
```

**Not the blocker.** Current Jetlag marks this task `ignore_errors: true`.

Check power:

```bash
ipmitool -I lanplus -H mgmt-<node>.rdu2.scalelab.redhat.com \
  -U <bmc-user> -P '<bmc-password>' chassis power status
# Chassis Power is off
```

If the chassis is already **off**, IPMI rejects another power-off. Safe to ignore
and focus on VirtualMediaInsert.

---

## Root cause

1. Jetlag probes iDRAC and, when Virtual Media is not under
   `Managers/iDRAC.Embedded.1`, treats the BMC as **iDRAC10+**.
2. For iDRAC10+, Insert uses `community.general.redfish_command` with
   `category: Systems` and `command: VirtualMediaInsert` (ISO URL from the
   bastion HTTP store).
3. Older `community.general` (e.g. **3.8.3**) only registers power/boot
   commands for `Systems`. `VirtualMediaInsert` is not a valid command → hard
   failure before any Redfish InsertMedia POST is usefully attempted.
4. The Jetlag venv was created with system **Python 3.6**, so Galaxy could not
   install a modern `community.general` that adds Systems VirtualMedia support.

```text
Python 3.6 venv → community.general 3.8.3
        ↓
redfish_command (Systems) has no VirtualMediaInsert
        ↓
boot-iso Insert fails (10 retries)
        ↓
mno-deploy cannot BMC-boot discovery ISO on r670
```

---

## Evidence

Collection / Python on the broken control host:

```bash
source /root/jetlag/.ansible/bin/activate   # or: source bootstrap.sh
python3 --version
# Python 3.6.8

ansible-galaxy collection list community.general
# community.general  3.8.3
```

The failure message lists only Systems power/boot commands — a **module
validation** error, not “ISO not found” or “Virtual Media detached” (those are
different Jetlag troubleshooting paths).

---

## Fix

Rebuild the Jetlag Ansible venv with **Python ≥ 3.9** and install a current
`community.general`.

```bash
# On the host that runs ansible-playbook (bastion / laptop)
dnf install -y python39 python39-pip   # or python3.11 if available

cd /root/jetlag   # adjust path
deactivate 2>/dev/null || true
rm -rf .ansible

python3.9 -m venv .ansible
source .ansible/bin/activate
pip install -U pip
pip install 'ansible<12.0.0' 'argcomplete<3.7.0' netaddr jmespath yq
ansible-galaxy collection install ansible.utils --force
ansible-galaxy collection install containers.podman --upgrade
ansible-galaxy collection install 'community.general>=9.0.0' --force
```

Then re-run deploy from that shell:

```bash
source /root/jetlag/.ansible/bin/activate
ansible-playbook -i ansible/inventory/<cloud>.local ansible/mno-deploy.yml
```

Optional one-off: re-source `bootstrap.sh` after the venv exists with Python 3.9+
so deps match the repo script — still ensure `community.general` is upgraded;
`bootstrap.sh` does not always pin it explicitly.

---

## Verify

```bash
source /root/jetlag/.ansible/bin/activate
python3 --version          # ≥ 3.9
ansible-galaxy collection list community.general   # ≥ 9.x
which ansible              # under .../jetlag/.ansible/bin/ansible
```

Re-run `mno-deploy`: Insert Virtual Media for r670 hosts should go `ok` (or fail
with a *different* Redfish/ISO/DNS message if something else is wrong).

---

## Related

- Jetlag upstream: `ansible/roles/boot-iso/tasks/dell.yml` (iDRAC10 detection,
  `VirtualMediaInsert`)
- Jetlag docs: `docs/troubleshooting.md` — other Virtual Media failures (ISO URL /
  BMC DNS, detached Virtual Media, iDRAC reset / job queue)
- Jetlag PR context: iDRAC10 + Scale Lab r670 support (`#878` and follow-ups)
)