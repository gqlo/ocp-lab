# Fedora CSB installation — bootable USB on a shared backup drive

Steps to prepare a USB drive that holds **personal backup data** and a **bootable Fedora CSB
installer** on separate partitions. Tested layout: Kingston DataTraveler 3.0 (~115 GiB), device
`/dev/sdb`.

CSB (Corporate Standard Base) is Red Hat IT’s internal Fedora Workstation image. The USB prep
below works for any hybrid Fedora/CSB installer ISO (~3 GiB); install the OS from the boot menu
after reboot.

## Goal

| Partition | Size | Role |
| --- | --- | --- |
| `sdb1` | 10 GiB | Bootable installer (`dd` target) |
| `sdb2` | remainder (~105 GiB) | ext4 backup storage |

Writing the ISO to **`sdb1` only** leaves **`sdb2`** untouched.

## Prerequisites

- Fedora CSB installer ISO, e.g. `~/Downloads/csb-fedora-44-2026-05-26.iso`
- USB drive with enough space for backups **and** a ~10 GiB boot partition
- Root/sudo on a Linux host (Fedora/RHEL)
- **Back up USB data elsewhere** before repartitioning — creating a GPT table wipes the old layout

## Identify the USB device

Device names (`sda`, `sdb`, …) change when you unplug/replug. Always confirm before destructive
commands:

```bash
lsblk -f
```

Expect something like:

```text
sdb           115G
├─sdb1         10G
└─sdb2        105G
```

Use **`/dev/sdb`** below only if that matches your USB — **not** your system disk.

## Step 1 — Repartition (GPT, 10 GiB + rest)

Unmount anything on the USB first:

```bash
sudo umount /dev/sdb* 2>/dev/null
sudo umount /home/otus/kingston 2>/dev/null
```

Create two partitions:

```bash
sudo parted -s /dev/sdb mklabel gpt
sudo parted -s /dev/sdb mkpart primary 1MiB 10GiB
sudo parted -s /dev/sdb mkpart primary 10GiB 100%

sudo parted /dev/sdb print
lsblk /dev/sdb
```

Expected `parted` output:

```text
Number  Start   End     Size    File system  Name     Flags
 1      1049kB  10.7GB  10.7GB               primary
 2      10.7GB  124GB   113GB                primary
```

## Step 2 — Format the backup partition (`sdb2`)

Do **not** format `sdb1` — the ISO write replaces its contents.

```bash
sudo mkfs.ext4 -L kingston-backup /dev/sdb2
sudo mkdir -p /home/otus/kingston
sudo mount /dev/sdb2 /home/otus/kingston
```

Restore backup files to `/home/otus/kingston`.

### Optional: persist mount in `/etc/fstab`

Use UUID so the mount survives device renames:

```bash
sudo blkid /dev/sdb2
```

Add a line like (replace UUID):

```text
UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  /home/otus/kingston  ext4  defaults  0  2
```

## Step 3 — Write the ISO to `sdb1`

```bash
sudo umount /dev/sdb1 2>/dev/null

ISO=~/Downloads/csb-fedora-44-2026-05-26.iso
sudo dd if="$ISO" of=/dev/sdb1 bs=4M status=progress conv=fsync
sync
```

| Target | Effect |
| --- | --- |
| `/dev/sdb1` | Correct — only the 10 GiB boot partition |
| `/dev/sdb` | **Wrong** — wipes both partitions |
| `/dev/sdb2` | **Wrong** — destroys backups |

After `dd`, `sdb1` often shows no normal filesystem in `lsblk`. That is expected.

## Step 4 — UEFI boot fix (if needed)

If the firmware does not list the USB, mark partition 1 as EFI System:

```bash
sudo gdisk /dev/sdb
```

In `gdisk`: `t` → `1` → `ef00` → `w` → confirm.

## Step 5 — Boot and install

1. Reboot and open the firmware boot menu (often F12, F10, Esc — machine-dependent).
2. Select the USB entry (sometimes listed as the Kingston device or the 10 GiB partition).
3. Prefer **`UEFI: …`** over legacy/CSM when installing on modern hardware.
4. Run Anaconda and complete the CSB install to the target disk.

## Filesystem check (legacy whole-disk layout)

If the USB previously had ext4 directly on `/dev/sdb` (no partition table) and you saw
`needs journal recovery` in `file -s /dev/sdb`, run **`e2fsck` before repartitioning** only if
you still need to read old data off that layout:

```bash
sudo umount /dev/sdb
sudo e2fsck -f /dev/sdb
```

After migrating to GPT + new partitions, this no longer applies to `sdb1`/`sdb2`.

## Pitfalls

| Mistake | Result |
| --- | --- |
| Copy ISO as a file onto ext4 | USB does not boot by itself |
| `mkfs.ext4` on `sdb1` before `dd` | Wasted step; `dd` overwrites it anyway |
| `dd` to `/dev/sdb` | Entire USB wiped, including backups |
| Assuming `/dev/sdb` is always the USB | Can overwrite the wrong disk — always `lsblk` first |

## Alternatives

**Ventoy** — install once, copy ISOs as files, pick from a boot menu. Requires repartitioning and
a full data backup first; simpler if you swap ISOs often.

**Whole-disk `dd`** — `dd if=image.iso of=/dev/sdb` is the standard single-purpose installer
stick, but it wipes the entire drive including backups.

**GRUB loopback** — keep the ISO as a file on ext4 and boot via a manual GRUB EFI setup; flexible
for Linux ISOs, more work than `dd` to `sdb1`.

## Quick reference

```bash
# Partition
sudo parted -s /dev/sdb mklabel gpt
sudo parted -s /dev/sdb mkpart primary 1MiB 10GiB
sudo parted -s /dev/sdb mkpart primary 10GiB 100%

# Backup partition
sudo mkfs.ext4 -L kingston-backup /dev/sdb2
sudo mount /dev/sdb2 /home/otus/kingston

# Boot partition
sudo dd if=~/Downloads/csb-fedora-44-2026-05-26.iso of=/dev/sdb1 bs=4M status=progress conv=fsync
sync
```
