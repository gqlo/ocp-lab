# nettools-fedora container image

Fedora-based toolbox image for OpenShift network tracing labs. Used by manifests in this directory (for example `dual-container.yaml`) and documented in depth in [`ocp-net-tracing.md`](ocp-net-tracing.md).

Published image: **`quay.io/rh_ee_lguoqing/nettools-fedora:latest`**

## What's in the image

| Category | Packages |
| -------- | -------- |
| Network capture | `tcpdump`, `wireshark-cli`, `conntrack-tools` |
| IP / DNS / routing | `iproute`, `iputils`, `bind-utils`, `net-tools`, `bridge-utils`, `ethtool` |
| Network testing | `curl`, `wget`, `nmap`, `nmap-ncat`, `nc`, `iperf3`, `socat`, `traceroute`, `telnet`, `mtr` |
| Process / system | `procps-ng`, `lsof`, `strace`, `iftop`, `iotop`, `htop` |
| Shell / utilities | `bash-completion`, `vim`, `less` |
| SSH | `openssh-server` (host keys generated at build time) |

To add or remove tools, edit the `dnf install` list in [`Dockerfile`](Dockerfile), then rebuild and push.

## Prerequisites

- Podman or Docker
- Network access to pull `fedora:latest` and push to Quay
- Quay credentials with **write** access to `quay.io/rh_ee_lguoqing/nettools-fedora` (for push; pull may work without login if the repo is public)

## Build

```bash
cd ocp-lab/learning/networking/ocp-network-tracing

podman build -t quay.io/rh_ee_lguoqing/nettools-fedora:latest -f Dockerfile .
```

Optional version tag (recommended when changing the package list):

```bash
podman build -t quay.io/rh_ee_lguoqing/nettools-fedora:v2 -f Dockerfile .
podman tag quay.io/rh_ee_lguoqing/nettools-fedora:v2 quay.io/rh_ee_lguoqing/nettools-fedora:latest
```

Using Docker instead of Podman:

```bash
docker build -t quay.io/rh_ee_lguoqing/nettools-fedora:latest -f Dockerfile .
```

## Test locally before pushing

```bash
podman run --rm -it quay.io/rh_ee_lguoqing/nettools-fedora:latest bash

# inside the container — spot-check a few tools
tcpdump --version
conntrack -V
sshd -V
```

## Push to Quay

```bash
podman login quay.io
podman push quay.io/rh_ee_lguoqing/nettools-fedora:latest
# if you tagged a version:
# podman push quay.io/rh_ee_lguoqing/nettools-fedora:v2
```

Clusters pick up the new image on the next pod creation that references `quay.io/rh_ee_lguoqing/nettools-fedora`. Delete and recreate existing pods if they must use the updated image immediately:

```bash
oc delete pod nettools-dual-pod
oc apply -f dual-container.yaml
```

## Pull only (consumer)

If you only need the published image on a workstation:

```bash
podman pull quay.io/rh_ee_lguoqing/nettools-fedora:latest
```

## Deploy test workloads

```bash
oc apply -f http-svc.yaml
oc apply -f dual-container.yaml
```

See [`ocp-net-tracing.md`](ocp-net-tracing.md) for tracing exercises using these workloads.

## SSH note

The image includes `openssh-server`, but manifests must start `sshd` explicitly if you want inbound SSH. For example:

```yaml
command:
- /bin/sh
- -c
- |
  /usr/sbin/sshd -D &
  sleep infinity
```

For interactive access without SSH, use `oc exec`:

```bash
oc exec -it nettools-dual-pod -c nettools-container-2 -- bash
```

## Troubleshooting Podman storage

If Podman fails with a **database configuration mismatch** (for example, storage created under a different `$HOME`):

```
Error: database static dir "/home/guoqingli/.local/share/containers/storage/libpod"
does not match our static dir "/home/otus/.local/share/containers/storage/libpod"
```

`podman system reset` cannot fix this because Podman reads the broken database before reset runs. Remove the stale storage manually, then retry:

```bash
rm -rf ~/.local/share/containers/storage
rm -rf ~/.config/containers   # optional
podman info
```

Alternatively, use a fresh storage root without deleting the old one:

```bash
mkdir -p ~/.local/share/containers/storage-otus

podman --root ~/.local/share/containers/storage-otus \
  build -t quay.io/rh_ee_lguoqing/nettools-fedora:latest -f Dockerfile .

podman --root ~/.local/share/containers/storage-otus \
  push quay.io/rh_ee_lguoqing/nettools-fedora:latest
```

Or build with Docker:

```bash
docker build -t quay.io/rh_ee_lguoqing/nettools-fedora:latest -f Dockerfile .
docker push quay.io/rh_ee_lguoqing/nettools-fedora:latest
```
