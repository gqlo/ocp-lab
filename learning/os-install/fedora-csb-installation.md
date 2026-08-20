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
| [Verify bootable](#verify-the-usb-is-bootable) | Checks before reboot |
| [Step 4 — Boot and install](#step-4--boot-and-install) | Firmware boot menu, GRUB `configfile` if needed, Anaconda |
| [Pitfalls](#pitfalls) | Common mistakes |

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

## Verify the USB is bootable

Run these checks **before** rebooting. They confirm the ISO landed correctly on `${USB}1`.

### 1 — Confirm the write size

Bytes copied by `dd` should match the ISO file size:

```bash
USB=/dev/sdc
ISO=~/Downloads/csb-fedora-44-2026-05-26.iso

stat -c '%s bytes (%n)' "$ISO"
sudo blockdev --getsize64 ${USB}1
```

`${USB}1` must be **at least** as large as the ISO (~3.3 GiB for current CSB images). The
`dd` byte count should match `stat` on the ISO.

### 2 — Inspect partition content

```bash
lsblk -f $USB
sudo file -s ${USB}1
sudo blkid ${USB}1
```

Expect ISO 9660 / UDF (hybrid installer layout). No normal `FSTYPE` in `lsblk` is fine.

Expected `file` output (CSB / Fedora 44 example):

```text
/dev/sdc1: ISO 9660 CD-ROM filesystem data (DOS/MBR boot sector) 'Fedora-E-dvd-x86_64-44' (bootable)
```

The **`(bootable)`** tag means the hybrid ISO boot structures are present on `${USB}1`.

Expected `blkid` output (same CSB / Fedora 44 image):

```text
/dev/sdc1: BLOCK_SIZE="2048" UUID="2026-04-22-13-38-48-00" LABEL="Fedora-E-dvd-x86_64-44" TYPE="iso9660" PTUUID="5d122ca8-3e16-4f53-bc40-9b84c96829f6" PTTYPE="gpt" PARTLABEL="primary" PARTUUID="c4bde114-b2a3-4232-b178-7da17f400107"
```

`TYPE="iso9660"` and the Fedora volume label confirm the installer ISO is on `${USB}1`. UUID
values differ per ISO build; the label and type are what matter.

`parted $USB print` may warn that not all space on `${USB}1` is used — the 10 GiB partition is
intentionally larger than the ~3.3 GiB ISO. Answer **`Ignore`** (or `I`):

```text
Warning: Not all of the space available to /dev/sdc1 appears to be used, you can fix the GPT to use all of the space (an extra 14446924 blocks) or continue with the current setting?
Fix/Ignore? Ignore
Model: Unknown (unknown)
Disk /dev/sdc1: 10.7GB
Sector size (logical/physical): 512B/512B
Partition Table: gpt
Disk Flags:

Number  Start   End     Size    File system  Name       Flags
 1      32.8kB  3326MB  3326MB               ISO9660    hidden, msftdata
 2      3326MB  3340MB  13.6MB  fat16        Appended2  boot, esp
```

That table is the **installer ISO’s internal layout** inside `${USB}1` (ISO9660 + EFI
`Appended2`), not the outer 10 GiB + backup table from [Step 1](#step-1--repartition-gpt-10-gib--rest).
The unused space warning is normal. For the outer GPT (`${USB}1` + `${USB}2`), use
`gdisk -l $USB` instead — it does not prompt.

### 3 — Check GPT partition type

```bash
sudo gdisk -l $USB
```

Expected outer GPT after [Step 1](#step-1--repartition-gpt-10-gib--rest) and
[Step 3](#step-3--write-the-iso-to-usb1) (Kingston example):

```text
GPT fdisk (gdisk) version 1.0.10

Partition table scan:
  MBR: protective
  BSD: not present
  APM: not present
  GPT: present

Found valid GPT with protective MBR; using GPT.
Disk /dev/sdc: 242155520 sectors, 115.5 GiB
Model: DataTraveler 3.0
Sector size (logical/physical): 512/512 bytes
Disk identifier (GUID): 64E7C77C-0F6F-4A82-9A3D-EDF57CA46A95
Partition table holds up to 128 entries
Main partition table begins at sector 2 and ends at sector 33
First usable sector is 34, last usable sector is 242155486
Partitions will be aligned on 2048-sector boundaries
Total free space is 4029 sectors (2.0 MiB)

Number  Start (sector)    End (sector)  Size       Code  Name
   1            2048        20971519   10.0 GiB    8300  primary
   2        20971520       242153471   105.5 GiB   8300  primary
```

| Partition | Expected | Notes |
| --- | --- | --- |
| 1 | 10.0 GiB, code **`8300`** | Installer lives here after `dd` |
| 2 | ~105 GiB, code **`8300`** | Backup ext4 |

GUIDs and sector counts vary by drive size; partition sizes and codes are what matter.

| Check | Good sign |
| --- | --- |
| `dd` byte count | Matches ISO size |
| `file -s ${USB}1` | `(bootable)` in output |
| `blkid ${USB}1` | `TYPE="iso9660"`, Fedora label |
| Partition 1 type | `8300`, 10.0 GiB on outer GPT |
| Firmware boot menu | Fedora/CSB installer, or a `grub>` prompt you can `configfile` ([Step 4](#step-4--boot-and-install)) |

Unused space inside the 10 GiB boot partition does **not** mean the stick failed — only the
ISO-sized region is written.

### 4 — Optional: dry-run boot in QEMU

Fedora/CSB installers are **UEFI-only**. QEMU defaults to legacy BIOS (SeaBIOS), which shows
`Booting from Hard Disk...` and never reaches the installer. Pass **OVMF** firmware and boot
**`${USB}1`** (the partition that received `dd`), not the whole disk.

Prepare writable UEFI variables once per host (copy from the read-only template):

```bash
cp /usr/share/OVMF/OVMF_VARS.fd /tmp/OVMF_VARS.fd
```

Boot the installer partition:

```bash
USB=/dev/sdc    # confirm with lsblk first

sudo umount ${USB}* 2>/dev/null

sudo qemu-system-x86_64 \
  -enable-kvm \
  -machine q35 \
  -m 4096 -smp 2 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=/tmp/OVMF_VARS.fd \
  -drive if=virtio,file=${USB}1,format=raw,readonly=on \
  -boot order=c
```

If the GRUB/Fedora menu appears, the stick is bootable. A `grub>` prompt can still be a good
sign for this layout — use the
[GRUB `configfile` workaround](#grub-configfile-workaround-iso-on-a-partition). The
definitive test is still a real reboot ([Step 4](#step-4--boot-and-install)).

**Alternative — boot the ISO file directly** (confirms the ISO, not the USB layout):

```bash
ISO=~/Downloads/csb-fedora-44-2026-05-26.iso

sudo qemu-system-x86_64 \
  -enable-kvm \
  -machine q35 \
  -m 4096 -smp 2 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=/tmp/OVMF_VARS.fd \
  -cdrom "$ISO" \
  -boot order=d
```

**What does not work in QEMU** (may still boot fine on real hardware):

| Approach | Symptom |
| --- | --- |
| No OVMF (SeaBIOS only) | Stuck at `Booting from Hard Disk...` |
| Whole disk `$USB` via `usb-storage` | UEFI loads GRUB, then drops to `grub>` — try [configfile](#grub-configfile-workaround-iso-on-a-partition) |
| `$USB` unset when using `sudo` | `A block device must be specified for "file"` |

## Step 4 — Boot and install

1. Reboot and open the firmware boot menu (often F12, F10, Esc — machine-dependent).
2. Select the USB entry (sometimes listed as the Kingston device or the 10 GiB partition).
3. Prefer **`UEFI: …`** over legacy/CSM when installing on modern hardware.
4. If the Fedora/CSB installer menu appears, continue into Anaconda. If you land at a
   **`grub>`** prompt instead, load the installer config as in
   [GRUB `configfile` workaround](#grub-configfile-workaround-iso-on-a-partition).
5. Run Anaconda and complete the CSB install to the target disk.

### GRUB `configfile` workaround (ISO on a partition)

Writing the ISO to **`${USB}1` only** (so `${USB}2` stays intact) often means firmware starts
GRUB without a `prefix` that points at `/boot/grub2/grub.cfg`. You get a bare `grub>` shell
instead of the Fedora installer menu.

At the GRUB prompt, list disks and confirm the ISO filesystem is on the first USB partition:

```text
ls
ls (hd0,gpt1)/
ls (hd0,gpt1)/boot/grub2/
```

Look for `grub.cfg` under `/boot/grub2/`. Then load it:

```text
configfile (hd0,gpt1)/boot/grub2/grub.cfg
```

The installer menu should appear. Continue with Anaconda as usual.

| If this happens | What to try |
| --- | --- |
| `(hd0,gpt1)` has no `/boot/grub2/grub.cfg` | `hd0` is probably the internal disk. Try `(hd1,gpt1)` (or the device `ls` showed for the USB). |
| `ls` lists several `hdN` | Probe each first GPT partition: `ls (hdN,gpt1)/boot/grub2/` until you see `grub.cfg`. |
| Path exists but `configfile` fails | `set root=(hd0,gpt1)` then `configfile /boot/grub2/grub.cfg`. |

This is expected for a **partition-level** hybrid ISO, not a failed `dd`. Whole-disk `dd` to
`$USB` usually boots the menu without this step, but it would wipe the backup partition.

## Pitfalls

| Mistake | Result |
| --- | --- |
| Copy ISO as a file onto ext4 | USB does not boot by itself |
| `mkfs.ext4` on `${USB}1` before `dd` | Wasted step; `dd` overwrites it anyway |
| `dd` to `$USB` (whole disk) | Entire USB wiped, including backups |
| Reusing an old `$USB` after replug | Can overwrite the wrong disk — always `lsblk` first |
| `rsync` without `--exclude='kingston'` | Copies into the mount under `$HOME` — fills the USB or loops |
| `dd` ISO to `${USB}1` (not whole disk) | GRUB may stop at `grub>` — load `configfile (hd0,gpt1)/boot/grub2/grub.cfg` |
| QEMU: whole `$USB` via `usb-storage`, no OVMF | `Booting from Hard Disk...` or `grub>` rescue — use OVMF + `${USB}1` ([verify §4](#4--optional-dry-run-boot-in-qemu)) |
