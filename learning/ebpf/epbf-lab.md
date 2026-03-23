# eBPF Generator for Specific Kernel Versions

This script allows you to create a Docker container with specific kernel versions for eBPF bcc tool installation. It extracts the appropriate UBI (Universal Base Image) version based on the kernel version and builds a container with all necessary kernel headers.

## Prerequisites

- A RHEL/CentOS machine or VM with:
  - Podman installed (`dnf install podman` if not already installed)
  - Valid Red Hat subscription activated
  - `subscription-manager` properly authenticated
  - Red Hat Subscription: The build process requires a valid Red Hat subscription since it needs to access RHEL repositories.
  - Subscription Mount: The script mounts the following directories from your host:
  - `/etc/pki/entitlement`
  - `/etc/rhsm`
  - `/etc/yum.repos.d/redhat.repo`


## Installation

Clone this repository:

```bash
git clone git@github.com:gqlo/ocp-workspace.git
cd ocp-workspace/learning/ebpf
```

## Usage

The script will automatically:
1. Generate a Dockerfile for the specified kernel version
2. Extract the appropriate UBI version from the kernel string
3. Install necessary dependencies (kernel headers, bpftrace, bpftool, etc.)
4. Build the container image

### Basic Usage

```bash
./build-ebpf.sh -k 5.14.0-427.40.1.el9_4.x86_64
```

