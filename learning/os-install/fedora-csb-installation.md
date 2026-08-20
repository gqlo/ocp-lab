# Fedora CSB installation — bootable USB on a shared backup drive

Steps to prepare a USB drive that holds **personal backup data** and a **bootable Fedora CSB
installer** on separate partitions. Tested layout: Kingston DataTraveler 3.0 (~115 GiB).

CSB (Corporate Standard Base) is Red Hat IT’s internal Fedora Workstation image. The USB prep
below works for any hybrid Fedora/CSB installer ISO (~3 GiB); install the OS from the boot menu
after reboot.

Device names shift when you unplug/replug (`sdb` → `sdc`, etc.). Set `USB` from `lsblk` before
every destructive command — examples below use **`/dev/sdc`** after a replug on one test host.

**Last Updated:** 2026-08-20

## Catalog

| Section | Topic |
| --- | ----- |
| [Goal](#goal) | Partition layout — 10 GiB boot + backup ext4 |
| [Prerequisites](#prerequisites) | ISO, space, sudo, backup before repartition |
| [Identify the USB device](#identify-the-usb-device) | Set `$USB` from `lsblk` |
| [Step 1 — Repartition](#step-1--repartition-gpt-10-gib--rest) | GPT: 10 GiB + remainder |
| [Step 2 — Format the backup partition](#step-2--format-the-backup-partition-usb2) | `mkfs.ext4`, mount `/home/otus/kingston` |
| [Back up home directory](#back-up-home-directory-to-homeotuskingston) | `rsync` `$HOME`; exclude `kingston`, `.cache` |
| [Optional: `/etc/fstab`](#optional-persist-mount-in-etcfstab) | Mount by UUID |
| [Step 3 — Write the ISO](#step-3--write-the-iso-to-usb1) | `dd` ISO to `${USB}1` only |
| [Step 4 — UEFI boot fix](#step-4--uefi-boot-fix-if-needed) | `gdisk` type `ef00` on partition 1 |
| [Step 5 — Boot and install](#step-5--boot-and-install) | Firmware boot menu, Anaconda |
| [Filesystem check (legacy layout)](#filesystem-check-legacy-whole-disk-layout) | `e2fsck` on old whole-disk ext4 |
| [Pitfalls](#pitfalls) | Common mistakes |
| [Alternatives](#alternatives) | Ventoy, whole-disk `dd`, GRUB loopback |
| [Quick reference](#quick-reference) | All commands on one page |

## Goal

| Partition | Size | Role |
| --- | --- | --- |
| `${USB}1` | 10 GiB | Bootable installer (`dd` target) |
| `${USB}2` | remainder (~105 GiB) | ext4 backup storage |

Writing the ISO to **`${USB}1` only** leaves **`${USB}2`** untouched.

## Prerequisites

- Fedora CSB installer ISO, e.g. `~/Downloads/csb-fedora-44-2026-05-26.iso`
- USB drive with enough space for backups **and** a ~10 GiB boot partition
- Root/sudo on a Linux host (Fedora/RHEL)
- **Back up USB data elsewhere** before repartitioning — creating a GPT table wipes the old layout

## Identify the USB device

```bash
lsblk -f
USB=/dev/sdc    # example — pick the Kingston ~115G disk, not your system disk
```

Expect something like:

```text
sdc           115G
├─sdc1         10G
└─sdc2        105G
```

## Step 1 — Repartition (GPT, 10 GiB + rest)

Unmount anything on the USB first:

```bash
USB=/dev/sdc    # confirm with lsblk first

sudo umount ${USB}* 2>/dev/null
sudo umount /home/otus/kingston 2>/dev/null
```

Create two partitions:

```bash
sudo parted -s $USB mklabel gpt
sudo parted -s $USB mkpart primary 1MiB 10GiB
sudo parted -s $USB mkpart primary 10GiB 100%

sudo parted $USB print
lsblk $USB
```

Expected `parted` output:

```text
Number  Start   End     Size    File system  Name     Flags
 1      1049kB  10.7GB  10.7GB               primary
 2      10.7GB  124GB   113GB                primary
```

## Step 2 — Format the backup partition (`${USB}2`)

Do **not** format `${USB}1` — the ISO write replaces its contents.

```bash
USB=/dev/sdc

sudo mkfs.ext4 -L kingston-backup ${USB}2
sudo mkdir -p /home/otus/kingston
sudo mount ${USB}2 /home/otus/kingston
```

### Back up home directory to `/home/otus/kingston`

Mount is under `$HOME`, so exclude it or `rsync` copies into itself.

```bash
# confirm mount
df -h /home/otus/kingston

sudo rsync -aAXHv --info=progress2 \
  --exclude='kingston' \
  --exclude='.cache' \
  /home/otus/ /home/otus/kingston/home-backup/
```

| Flag / option | Purpose |
| --- | --- |
| `-a` | Archive mode — permissions, times, symlinks, etc. |
| `-A` | Preserve ACLs |
| `-X` | Preserve extended attributes |
| `-H` | Preserve hard links |
| `--info=progress2` | Overall transfer progress |
| `--exclude='kingston'` | Skip the USB mount inside `$HOME` |
| `--exclude='.cache'` | Skip `~/.cache` (large, regenerates after restore) |

Dry run first:

```bash
sudo rsync -aAXHv --dry-run --info=progress2 \
  --exclude='kingston' \
  --exclude='.cache' \
  /home/otus/ /home/otus/kingston/home-backup/
```

Notes:

- Trailing `/` on `/home/otus/` copies **contents** into `home-backup/` (includes dotfiles).
- Re-run the same `rsync` command to update an existing backup; only changed files transfer.
- Ensure the backup partition has enough free space for all of `$HOME`.
- Add more `--exclude='…'` lines for other bulky paths (e.g. `.local/share/Trash/`).

### Optional: persist mount in `/etc/fstab`

Use UUID so the mount survives device renames (`sdb` → `sdc`, etc.):

```bash
sudo blkid ${USB}2
```

Add a line like (replace UUID):

```text
UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  /home/otus/kingston  ext4  defaults  0  2
```

## Step 3 — Write the ISO to `${USB}1`

```bash
USB=/dev/sdc
ISO=~/Downloads/csb-fedora-44-2026-05-26.iso

sudo umount ${USB}1 2>/dev/null
sudo dd if="$ISO" of=${USB}1 bs=4M status=progress conv=fsync
sync
```

| Target | Effect |
| --- | --- |
| `${USB}1` | Correct — only the 10 GiB boot partition |
| `$USB` (whole disk) | **Wrong** — wipes both partitions |
| `${USB}2` | **Wrong** — destroys backups |

After `dd`, `${USB}1` often shows no normal filesystem in `lsblk`. That is expected.

## Step 4 — UEFI boot fix (if needed)

If the firmware does not list the USB, mark partition 1 as EFI System:

```bash
USB=/dev/sdc
sudo gdisk $USB
```

In `gdisk`: `t` → `1` → `ef00` → `w` → confirm.

## Step 5 — Boot and install

1. Reboot and open the firmware boot menu (often F12, F10, Esc — machine-dependent).
2. Select the USB entry (sometimes listed as the Kingston device or the 10 GiB partition).
3. Prefer **`UEFI: …`** over legacy/CSM when installing on modern hardware.
4. Run Anaconda and complete the CSB install to the target disk.

## Filesystem check (legacy whole-disk layout)

If the USB previously had ext4 directly on the whole disk (no partition table) and you saw
`needs journal recovery` in `file -s`, run **`e2fsck` before repartitioning** only if you still
need to read old data off that layout:

```bash
USB=/dev/sdc
sudo umount $USB
sudo e2fsck -f $USB
```

After migrating to GPT + new partitions, this no longer applies to `${USB}1`/`${USB}2`.

## Pitfalls

| Mistake | Result |
| --- | --- |
| Copy ISO as a file onto ext4 | USB does not boot by itself |
| `mkfs.ext4` on `${USB}1` before `dd` | Wasted step; `dd` overwrites it anyway |
| `dd` to `$USB` (whole disk) | Entire USB wiped, including backups |
| Reusing an old `$USB` after replug | Can overwrite the wrong disk — always `lsblk` first |
| `rsync` without `--exclude='kingston'` | Copies into the mount under `$HOME` — fills the USB or loops |

## Alternatives

**Ventoy** — install once, copy ISOs as files, pick from a boot menu. Requires repartitioning and
a full data backup first; simpler if you swap ISOs often.

**Whole-disk `dd`** — `dd if=image.iso of=$USB` is the standard single-purpose installer stick,
but it wipes the entire drive including backups.

**GRUB loopback** — keep the ISO as a file on ext4 and boot via a manual GRUB EFI setup; flexible
for Linux ISOs, more work than `dd` to `${USB}1`.

## Quick reference

```bash
lsblk -f
USB=/dev/sdc    # set to your Kingston USB

# Partition
sudo parted -s $USB mklabel gpt
sudo parted -s $USB mkpart primary 1MiB 10GiB
sudo parted -s $USB mkpart primary 10GiB 100%

# Backup partition
sudo mkfs.ext4 -L kingston-backup ${USB}2
sudo mount ${USB}2 /home/otus/kingston

# Home backup
sudo rsync -aAXHv --info=progress2 \
  --exclude='kingston' \
  --exclude='.cache' \
  /home/otus/ /home/otus/kingston/home-backup/

# Boot partition
sudo dd if=~/Downloads/csb-fedora-44-2026-05-26.iso of=${USB}1 bs=4M status=progress conv=fsync
sync
```
