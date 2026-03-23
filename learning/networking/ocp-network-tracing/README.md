# OpenShift Network Tracing

## Table of Contents

- [Overview](#overview)
- [Contents](#contents)
  - [Dockerfile](#dockerfile)
  - [YAML Manifests](#yaml-manifests)
- [Configuration](#configuration)
  - [Building the Networking Tools Container](#building-the-networking-tools-container)
  - [Pushing the Image to Quay](#pushing-the-image-to-quay)
  - [Deploying the Test Application](#deploying-the-test-application)
- [Tracing](#tracing)
  - [Container-to-Container Communication](#container-to-container-communication)
    - [Shared Network Namespace](#shared-network-namespace)
    - [Process Isolation](#process-isolation)
    - [Filesystem Isolation](#filesystem-isolation)
    - [Connection Tracking with conntrack](#connection-tracking-with-conntrack)
    - [Packet Capture with tcpdump](#packet-capture-with-tcpdump)
  - [Understanding the Node Network Stack](#understanding-the-node-network-stack)
    - [OVS Topology on a Physical Node](#ovs-topology-on-a-physical-node)
    - [Container, Veth Pair, and Physical NIC](#container-veth-pair-and-physical-nic)
    - [Comparing Capture Points: veth, eth0, and Physical NIC](#comparing-capture-points-veth-eth0-and-physical-nic)
  - [Tracing a Packet from Pod to the Internet](#tracing-a-packet-from-pod-to-the-internet)
    - [Packet Path Overview](#packet-path-overview)
    - [Prerequisites](#prerequisites)
    - [Step 1: Capture at Pod eth0](#step-1-capture-at-pod-eth0)
    - [Step 2: Find the Host-Side veth](#step-2-find-the-host-side-veth)
    - [Step 3: Capture at Host veth](#step-3-capture-at-host-veth)
    - [Step 4: Capture at Physical NIC (SNAT Observed)](#step-4-capture-at-physical-nic-snat-observed)
    - [Step 5: Verify with conntrack on the Node](#step-5-verify-with-conntrack-on-the-node)
    - [Step 6: Confirm the OVN SNAT Rule](#step-6-confirm-the-ovn-snat-rule)
    - [Step 7: Capture at the Bastion Host (Second SNAT)](#step-7-capture-at-the-bastion-host-second-snat)
    - [Summary](#summary)
- [Requirements](#requirements)
- [Notes](#notes)
- [References](#references)

## Overview

This directory provides a comprehensive set of tools for network analysis, packet capture, and troubleshooting in OpenShift environments. It includes a container image with essential networking tools and example YAML manifests for deploying network test scenarios.

## Contents

### Dockerfile

The `Dockerfile` builds a container image based on Fedora that includes a set of networking and troubleshooting tools:

**Network Analysis Tools:**
- `tcpdump` - Packet capture and analysis
- `wireshark-cli` - Command-line network protocol analyzer
- `conntrack-tools` - Connection tracking utilities

**Network Utilities:**
- `iproute`, `iputils` - IP and routing management
- `bind-utils` - DNS troubleshooting (dig, nslookup)
- `net-tools` - Traditional networking utilities (ifconfig, netstat)
- `bridge-utils`, `ethtool` - Bridge and Ethernet interface management

**Network Testing:**
- `curl`, `wget` - HTTP/HTTPS testing
- `nmap-ncat`, `nc` - Network connectivity testing
- `iperf3` - Network performance testing
- `nmap` - Network scanning
- `traceroute` - Route tracing
- `telnet` - Interactive network testing
- `socat` - Multipurpose relay tool

**Monitoring Tools:**
- `iftop` - Network interface bandwidth monitoring
- `iotop` - I/O monitoring
- `htop` - Process monitoring
- `mtr` - Network diagnostic tool

**System Tools:**
- `procps-ng` - Process utilities
- `lsof` - List open files/connections
- `strace` - System call tracing

**Utilities:**
- `bash-completion`, `vim`, `less` - Enhanced shell experience

### YAML Manifests

#### http-svc.yaml

A complete OpenShift application manifest that includes:
- **ConfigMap** (`static-content`) - Sample static content
- **ConfigMap** (`nginx-config`) - Nginx server configuration
- **Deployment** (`static-server`) - Nginx-based static content server
- **Service** (`static-server`) - ClusterIP service exposing the deployment
- **Routes** - HTTP and HTTPS routes for external access

This manifest can be used to:
- Test network connectivity between pods and services
- Verify route functionality
- Create a test endpoint for network tracing exercises

#### dual-container.yaml

A Pod manifest that creates a single pod with two containers sharing the same network namespace, designed for container-to-container communication tracing:
- **Pod** (`nettools-dual-pod`) - Contains two `nettools-fedora` containers
- **Container 1** (`nettools-container-1`) - Runs a Python HTTP server on port 8080 serving content from `/tmp`
- **Container 2** (`nettools-container-2`) - Runs `sleep infinity` for interactive access
- Both containers run with a privileged security context and share the same pod network namespace

Used for network tracing exercises to capture and analyze HTTP traffic between containers within the same pod.

## Configuration

### Building the Networking Tools Container

```bash
# Build the container image
podman build -t nettools-fedora:latest .
```

### Pushing the Image to Quay

```bash
# Tag the image
podman tag localhost/nettools-fedora:latest quay.io/<your-username>/nettools-fedora:latest

# Push the image to the remote registry
podman push quay.io/<your-username>/nettools-fedora:latest
```

### Deploying the Test Application

```bash
# Deploy the HTTP service for testing
oc apply -f http-svc.yaml
```

```bash
# Deploy a pod with two containers
oc apply -f dual-container.yaml
```

---

## Tracing

### Container-to-Container Communication

Once we have deployed the dual-container pod, we should see the following pod running:

```bash
$ oc get pod -n network-trace | grep dual
nettools-dual-pod                2/2     Running   0          5d22h
```

#### Shared Network Namespace

Since containers within the same pod share a network namespace, their NIC and MAC addresses are identical.

**Container 1:**
```bash
$ oc rsh -c nettools-container-1 -n network-trace nettools-dual-pod
sh-5.1# ip a
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host 
       valid_lft forever preferred_lft forever
2: eth0@if4615: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400 qdisc noqueue state UP group default 
    link/ether 0a:58:0a:80:02:2b brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 10.128.2.43/23 brd 10.128.3.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::858:aff:fe80:22b/64 scope link 
       valid_lft forever preferred_lft forever
```

**Container 2:**
```bash
$ oc rsh -c nettools-container-2 -n network-trace nettools-dual-pod
sh-5.1# ip a
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host 
       valid_lft forever preferred_lft forever
2: eth0@if4615: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400 qdisc noqueue state UP group default 
    link/ether 0a:58:0a:80:02:2b brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 10.128.2.43/23 brd 10.128.3.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::858:aff:fe80:22b/64 scope link 
       valid_lft forever preferred_lft forever
```

Both containers report the same `eth0@if4615` with IP `10.128.2.43` and MAC `0a:58:0a:80:02:2b`, confirming the shared network namespace.

#### Process Isolation

Although the network namespace is shared, each container has its own process namespace. Container 2 can only see `sleep infinity`, while Container 1 can only see the Python HTTP server:

**Container 2:**
```bash
$ oc rsh -c nettools-container-2 -n network-trace nettools-dual-pod
sh-5.1# ps aux
USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root           1  0.0  0.0   2624  1024 ?        Ss   Nov17   0:00 sleep infinity
root          13  0.0  0.0   4424  3584 pts/0    Ss   02:08   0:00 /bin/sh
root          14  0.0  0.0   7008  2560 pts/0    R+   02:08   0:00 ps aux
```

**Container 1:**
```bash
$ oc rsh -c nettools-container-1 -n network-trace nettools-dual-pod
sh-5.1# ps aux
USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root           1  0.0  0.0  96720 16384 ?        Ss   Nov17   0:12 python3 -m http.server 8080
root           8  0.0  0.0   4424  3584 pts/0    Ss   02:08   0:00 /bin/sh
root           9  0.0  0.0   7008  2560 pts/0    R+   02:09   0:00 ps aux
```

#### Filesystem Isolation

Each container also has its own filesystem. Create a file in Container 1 and verify it does not appear in Container 2:

**Container 1:**
```bash
$ oc rsh -c nettools-container-1 -n network-trace nettools-dual-pod
sh-5.1# echo "container 1" >> /tmp/container-1.txt
sh-5.1# cat /tmp/container-1.txt 
container 1
```

**Container 2:**
```bash
$ oc rsh -c nettools-container-2 -n network-trace nettools-dual-pod
sh-5.1# ls /tmp/
sh-5.1# 
```

The file does not exist in Container 2, confirming filesystem isolation.

#### Connection Tracking with conntrack

Use `conntrack -E` to watch real-time connection events. Start the event listener in Container 1, then curl the HTTP server from Container 2:

**Container 1 (listener):**
```bash
$ oc rsh -c nettools-container-1 -n network-trace nettools-dual-pod
sh-5.1# conntrack -E
    [NEW] tcp      6 120 SYN_SENT src=127.0.0.1 dst=127.0.0.1 sport=51000 dport=8080 [UNREPLIED] src=127.0.0.1 dst=127.0.0.1 sport=8080 dport=51000
 [UPDATE] tcp      6 60 SYN_RECV src=127.0.0.1 dst=127.0.0.1 sport=51000 dport=8080 src=127.0.0.1 dst=127.0.0.1 sport=8080 dport=51000
 [UPDATE] tcp      6 432000 ESTABLISHED src=127.0.0.1 dst=127.0.0.1 sport=51000 dport=8080 src=127.0.0.1 dst=127.0.0.1 sport=8080 dport=51000 [ASSURED]
 [UPDATE] tcp      6 120 FIN_WAIT src=127.0.0.1 dst=127.0.0.1 sport=51000 dport=8080 src=127.0.0.1 dst=127.0.0.1 sport=8080 dport=51000 [ASSURED]
 [UPDATE] tcp      6 30 LAST_ACK src=127.0.0.1 dst=127.0.0.1 sport=51000 dport=8080 src=127.0.0.1 dst=127.0.0.1 sport=8080 dport=51000 [ASSURED]
 [UPDATE] tcp      6 120 TIME_WAIT src=127.0.0.1 dst=127.0.0.1 sport=51000 dport=8080 src=127.0.0.1 dst=127.0.0.1 sport=8080 dport=51000 [ASSURED]
[DESTROY] tcp      6 TIME_WAIT src=127.0.0.1 dst=127.0.0.1 sport=49368 dport=8080 src=127.0.0.1 dst=127.0.0.1 sport=8080 dport=49368 [ASSURED]
[DESTROY] tcp      6 TIME_WAIT src=127.0.0.1 dst=127.0.0.1 sport=33924 dport=8080 src=127.0.0.1 dst=127.0.0.1 sport=8080 dport=33924 [ASSURED]
```

**Container 2 (client):**
```bash
$ oc rsh -c nettools-container-2 -n network-trace nettools-dual-pod
sh-5.1# curl http://127.0.0.1:8080/hello.txt
Hello World
```

Since both containers share the network namespace, Container 2 reaches Container 1's HTTP server via `127.0.0.1`. The conntrack output shows the full TCP lifecycle: `SYN_SENT` -> `SYN_RECV` -> `ESTABLISHED` -> `FIN_WAIT` -> `LAST_ACK` -> `TIME_WAIT` -> `DESTROY`.

#### Packet Capture with tcpdump

For packet-level details, start tcpdump on the loopback device in Container 1, then curl from Container 2:

**Container 1 (capture):**
```bash
$ oc rsh -c nettools-container-1 -n network-trace nettools-dual-pod
sh-5.1# tcpdump -i lo -nn -A 'port 8080 and (host 127.0.0.1)'
dropped privs to tcpdump
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on lo, link-type EN10MB (Ethernet), snapshot length 262144 bytes

02:32:28.679560 IP 127.0.0.1.39630 > 127.0.0.1.8080: Flags [S], seq 388646906, win 65495, options [mss 65495,sackOK,TS val 2431590157 ecr 0,nop,wscale 7], length 0
E..<..@.@................*G..........0.........
............
02:32:28.679581 IP 127.0.0.1.8080 > 127.0.0.1.39630: Flags [S.], seq 3084335693, ack 388646907, win 65483, options [mss 65495,sackOK,TS val 2431590157 ecr 2431590157,nop,wscale 7], length 0
E..<..@.@.<...............:M.*G......0.........
............
02:32:28.679593 IP 127.0.0.1.39630 > 127.0.0.1.8080: Flags [.], ack 1, win 512, options [nop,nop,TS val 2431590157 ecr 2431590157], length 0
E..4..@.@................*G...:N.....(.....
.......                      
02:32:28.679638 IP 127.0.0.1.39630 > 127.0.0.1.8080: Flags [P.], seq 1:88, ack 1, win 512, options [nop,nop,TS val 2431590157 ecr 2431590157], length 87: HTTP: GET /hello.txt HTTP/1.1
E.....@.@................*G...:N...........                                                                                                                                                                              
........GET /hello.txt HTTP/1.1
Host: 127.0.0.1:8080
User-Agent: curl/7.82.0
Accept: */*


02:32:28.679642 IP 127.0.0.1.8080 > 127.0.0.1.39630: Flags [.], ack 88, win 511, options [nop,nop,TS val 2431590157 ecr 2431590157], length 0
E..4T.@.@.................:N.*HR.....(.....
.......
02:32:28.681580 IP 127.0.0.1.8080 > 127.0.0.1.39630: Flags [P.], seq 1:187, ack 88, win 512, options [nop,nop,TS val 2431590159 ecr 2431590157], length 186: HTTP: HTTP/1.0 200 OK
E...T.@.@..5..............:N.*HR...........
........HTTP/1.0 200 OK
Server: SimpleHTTP/0.6 Python/3.10.4
Date: Tue, 18 Nov 2025 02:32:28 GMT
Content-type: text/plain
Content-Length: 12
Last-Modified: Mon, 17 Nov 2025 08:08:08 GMT
02:32:28.681608 IP 127.0.0.1.39630 > 127.0.0.1.8080: Flags [.], ack 187, win 511, options [nop,nop,TS val 2431590159 ecr 2431590159], length 0
E..4..@.@................*HR..;......(.....
........
02:32:28.681675 IP 127.0.0.1.8080 > 127.0.0.1.39630: Flags [P.], seq 187:199, ack 88, win 512, options [nop,nop,TS val 2431590159 ecr 2431590159], length 12: HTTP
E..@T.@.@.................;..*HR.....4.....
........Hello World

02:32:28.681684 IP 127.0.0.1.39630 > 127.0.0.1.8080: Flags [.], ack 199, win 511, options [nop,nop,TS val 2431590159 ecr 2431590159], length 0
E..4..@.@................*HR..;......(.....
........
02:32:28.681774 IP 127.0.0.1.8080 > 127.0.0.1.39630: Flags [F.], seq 199, ack 88, win 512, options [nop,nop,TS val 2431590159 ecr 2431590159], length 0
E..4T.@.@.................;..*HR.....(.....
........
02:32:28.681894 IP 127.0.0.1.39630 > 127.0.0.1.8080: Flags [F.], seq 88, ack 200, win 512, options [nop,nop,TS val 2431590159 ecr 2431590159], length 0
E..4..@.@................*HR..;......(.....
........
02:32:28.681934 IP 127.0.0.1.8080 > 127.0.0.1.39630: Flags [.], ack 89, win 512, options [nop,nop,TS val 2431590159 ecr 2431590159], length 0
E..4T.@.@.................;..*HS.....(.....
........
^C
12 packets captured
24 packets received by filter
0 packets dropped by kernel
```

**Container 2 (client):**
```bash
$ oc rsh -c nettools-container-2 -n network-trace nettools-dual-pod
sh-5.1# curl http://127.0.0.1:8080/hello.txt
Hello World
```

The tcpdump output shows the complete HTTP transaction over TCP: the three-way handshake (`[S]`, `[S.]`, `[.]`), the `GET /hello.txt` request, the `200 OK` response with `Hello World`, and the connection teardown (`[F.]`). All traffic flows over loopback (`127.0.0.1`) since both containers share the same network namespace.

---

### Understanding the Node Network Stack

#### OVS Topology on a Physical Node

The OVS topology on a node consists of two bridges. `br-ex` connects to the physical NIC (`ens2f0np0`) and includes 3 ports. `br-int` has N ports that connect all the containers via veth pairs:

```bash
sh-5.1# ovs-vsctl show
cbab9023-5b75-43cc-93fd-61db4e0d387f
    Bridge br-ex
        Port ens2f0np0
            Interface ens2f0np0
                type: system
        Port br-ex
            Interface br-ex
                type: internal
        Port patch-br-ex_m42-h32-000-r650-to-br-int
            Interface patch-br-ex_m42-h32-000-r650-to-br-int
                type: patch
                options: {peer=patch-br-int-to-br-ex_m42-h32-000-r650}
    Bridge br-int
        fail_mode: secure
        datapath_type: system
        Port "7be093806debefd"
            Interface "7be093806debefd"
        Port "4952fbdba0f3a02"
            Interface "4952fbdba0f3a02"
        ...
        [~150 more container veth interfaces]
        ...
        Port patch-br-int-to-br-ex_m42-h32-000-r650
            Interface patch-br-int-to-br-ex_m42-h32-000-r650
                type: patch
                options: {peer=patch-br-ex_m42-h32-000-r650-to-br-int}
        Port ovn-k8s-mp0
            Interface ovn-k8s-mp0
                type: internal
        Port ovn-91667b-0
            Interface ovn-91667b-0
                type: geneve
                options: {csum="true", key=flow, local_ip="198.18.0.9", remote_ip="198.18.0.7"}
        Port ovn-ae72c2-0
            Interface ovn-ae72c2-0
                type: geneve
                options: {csum="true", key=flow, local_ip="198.18.0.9", remote_ip="198.18.0.8"}
        ...
        [3 more Geneve tunnels to nodes .5, .6, .10]
        ...
        Port br-int
            Interface br-int
                type: internal
    ovs_version: "3.4.3-66.el9fdp"
```

Here is a high-level diagram of the two bridges and the ports connected to them:

```
External Network/Internet
        |
        | (Ethernet cable plugged into Port 1)
        v
+---------------------------------------+
|       Switch: br-ex                   |
|       (3-port switch)                 |
|                                       |
|  [Port 1]  [Port 2]  [Port 3]       |
|     |         |         |             |
|     |         |         +--------+    |
|  ens2f0np0  br-ex            patch   |
|  (physical) (virtual)      (virtual) |
+-------------------------------+------+
                                |
                  Virtual Patch Cable
                  (like an Ethernet cable)
                                |
+-------------------------------+------+
|       Switch: br-int                 |
|       (157-port switch)              |
|                                      |
|  [Port 1] [Port 2] [Port 3] ... [N] |
|     |        |        |              |
|   patch    veth1    veth2    ... more |
|  (from     (to      (to             |
|   br-ex)   pod-1)   pod-2)          |
+----------+---------+----------------+
           |         |
       Container1  Container2  ... (~150 containers)
```

#### Container, Veth Pair, and Physical NIC

This section demonstrates how to trace the connection between a container's network interface, its host-side veth pair, and the physical NIC on the node.

**Find the node where the pod is running:**

```bash
$ oc get pod -o wide -n network-trace 
NAME                             READY   STATUS    RESTARTS   AGE   IP             NODE               NOMINATED NODE   READINESS GATES
nettools-dual-pod                2/2     Running   0          15d   10.128.2.43    m42-h32-000-r650   <none>           <none>
```

**Verify connectivity from the node to the pod:**

```bash
$ oc debug node/m42-h32-000-r650
sh-5.1# chroot /host
sh-5.1# curl http://10.128.2.43:8080/hello.txt
Hello World
```

**Use `crictl` to find the containers running on this host:**

```bash
sh-5.1# crictl ps | grep dual
da7e98b24503f  quay.io/rh_ee_lguoqing/nettools-fedora@sha256:...  2 weeks ago  Running  nettools-container-2  0  7be093806debe  nettools-dual-pod
b5ec119e63fa6  quay.io/rh_ee_lguoqing/nettools-fedora@sha256:...  2 weeks ago  Running  nettools-container-1  0  7be093806debe  nettools-dual-pod
```

**Examine the network namespace of this pod:**

```bash
sh-5.1# crictl inspectp 7be093806debe | jq -r '.info.runtimeSpec.linux.namespaces[] | select(.type=="network").path'
/var/run/netns/67f12702-ca28-499f-b79f-e317ce158fe2
```

**Enter that network namespace and examine the network interfaces.** We see `eth0@if4615`, which tells us that this eth0 interface is connected to interface index 4615 on the other side -- in this case, an interface on the host:

```bash
sh-5.1# nsenter --net=/var/run/netns/67f12702-ca28-499f-b79f-e317ce158fe2
[root@m42-h32-000-r650 /]# ip a
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host 
       valid_lft forever preferred_lft forever
2: eth0@if4615: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400 qdisc noqueue state UP group default 
    link/ether 0a:58:0a:80:02:2b brd ff:ff:ff:ff:ff:ff link-netns b4c80c54-362d-405e-8c54-a170a7de8386
    inet 10.128.2.43/23 brd 10.128.3.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::858:aff:fe80:22b/64 scope link 
       valid_lft forever preferred_lft forever
```

**Find the host-side veth by grepping for the interface index.** The container-side `2: eth0@if4615` pairs with `4615: 7be093806debefd@if2`. Note that the interface name matches the pod sandbox ID. See [[1]](#references) for more information on Linux virtual interfaces:

```bash
sh-5.1# ip link show | grep 4615
4615: 7be093806debefd@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400 qdisc noqueue master ovs-system state UP mode DEFAULT group default 
```

The output also shows that veth 4615 is enslaved by a master called `ovs-system`. The details of this interface confirm it is an Open vSwitch [[2]](#references) interface, not a standard Linux network interface. The OVN-Kubernetes [[3]](#references) architecture diagram shows how OVS fits into the picture:

```bash
sh-5.1# ip -d link show ovs-system
11: ovs-system: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN mode DEFAULT group default qlen 1000
    link/ether e2:43:fd:d1:2e:58 brd ff:ff:ff:ff:ff:ff promiscuity 1  allmulti 0 minmtu 68 maxmtu 65535 
    openvswitch addrgenmode eui64 numtxqueues 1 numrxqueues 1 gso_max_size 65536 gso_max_segs 65535 tso_max_size 65536 tso_max_segs 65535 gro_max_size 65536 gso_ipv4_max_size 65536 gro_ipv4_max_size 65536
```

There are 3 devices associated with `ovs-system`: `ens2f0np0` (the physical NIC), `ovs-system` itself, and `genev_sys_6081` (for Geneve tunneling):

```bash
sh-5.1# ip link show | grep "ovs-system" | grep -v "@if"
8: ens2f0np0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq master ovs-system state UP mode DEFAULT group default qlen 1000
11: ovs-system: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN mode DEFAULT group default qlen 1000
14: genev_sys_6081: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 65000 qdisc noqueue master ovs-system state UNKNOWN mode DEFAULT group default qlen 1000
```

#### Comparing Capture Points: veth, eth0, and Physical NIC

Now let's capture packets at three different points to observe how the source IP changes as a packet leaves the pod.

**Capture on the host-side veth port:**

```bash
$ oc debug node/m42-h32-000-r650
sh-5.1# tcpdump -i 7be093806debefd -n
listening on 7be093806debefd, link-type EN10MB (Ethernet), snapshot length 262144 bytes
04:50:13.113152 IP 10.128.2.43 > 8.8.8.8: ICMP echo request, id 15, seq 1, length 64
04:50:13.127747 IP 8.8.8.8 > 10.128.2.43: ICMP echo reply, id 15, seq 1, length 64
04:50:18.590973 ARP, Request who-has 10.128.2.1 tell 10.128.2.43, length 28
04:50:18.591379 ARP, Reply 10.128.2.1 is-at 0a:58:a9:fe:01:01, length 28
```

**Capture on the container's eth0:**

```bash
$ oc rsh nettools-dual-pod
sh-5.1# tcpdump -i eth0 -n
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
04:50:13.113137 IP 10.128.2.43 > 8.8.8.8: ICMP echo request, id 15, seq 1, length 64
04:50:13.127754 IP 8.8.8.8 > 10.128.2.43: ICMP echo reply, id 15, seq 1, length 64
04:50:18.590915 ARP, Request who-has 10.128.2.1 tell 10.128.2.43, length 28
04:50:18.591382 ARP, Reply 10.128.2.1 is-at 0a:58:a9:fe:01:01, length 28
```

**Capture on the physical NIC:**

```bash
$ oc debug node/m42-h32-000-r650
sh-5.1# tcpdump icmp -i ens2f0np0 -n
listening on ens2f0np0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
04:50:13.115888 IP 198.18.0.9 > 8.8.8.8: ICMP echo request, id 15, seq 1, length 64
04:50:13.124988 IP 8.8.8.8 > 198.18.0.9: ICMP echo reply, id 15, seq 1, length 64
```

**Send an ICMP packet from inside the pod's network namespace:**

```bash
$ oc debug node/m42-h32-000-r650
sh-5.1# chroot /host
sh-5.1# nsenter --net=/var/run/netns/67f12702-ca28-499f-b79f-e317ce158fe2
[root@m42-h32-000-r650 /]# ping 8.8.8.8 -c 1
PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
64 bytes from 8.8.8.8: icmp_seq=1 ttl=107 time=14.5 ms

--- 8.8.8.8 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 14.507/14.507/14.507/0.000 ms
```

The tcpdump output on the host-side veth and the container's eth0 looks almost identical, which is exactly what we expect for a veth pair -- can you spot the difference? (Hint: look at the timestamps.)

On the physical NIC, however, the source IP changed from `10.128.2.43` to `198.18.0.9`, indicating that SNAT is being performed at the OVN layer. The next section walks through this transformation step by step.

---

## Tracing a Packet from Pod to the Internet

This exercise walks through tracing an ICMP packet from a pod all the way to the internet, capturing it at every network hop to observe exactly where SNAT (Source Network Address Translation) occurs. In this lab environment, the packet undergoes **two SNATs**: first by the OVN gateway router on the node, then by the bastion host that routes the cluster to the external network. By the end, you will see how the pod IP transforms at each hop.

### Packet Path Overview

```
Pod eth0 (10.128.2.43)
    |
    v
Host veth 7be093806debefd (10.128.2.43)    <-- still pod IP
    |
    v
OVS br-int
    | patch port
    v
OVS br-ex -- OVN Gateway Router performs SNAT #1 here
    |
    v
Node physical NIC ens2f0np0 (198.18.0.9)   <-- node IP (1st SNAT)
    |
    v  198.18.0.0/16 network
    |
Bastion ens2f0np0 (198.18.0.1)             <-- receives packet with node IP
    |
    v  iptables MASQUERADE performs SNAT #2
    |
Bastion eno12399 (10.6.62.29)              <-- bastion IP (2nd SNAT)
    |
    v  10.6.62.0/24 lab network -> default gateway 10.6.62.254
    |
Internet (8.8.8.8)
```

A quick `traceroute` from the pod confirms this path:

```bash
$ oc exec -n network-trace nettools-dual-pod -c nettools-container-1 -- traceroute -n 8.8.8.8
traceroute to 8.8.8.8 (8.8.8.8), 30 hops max, 60 byte packets
 1  8.8.8.8  3.542 ms  3.671 ms  3.754 ms
 2  100.64.0.6  5.959 ms  5.990 ms  5.901 ms
 3  198.18.0.1  7.508 ms  7.617 ms  7.469 ms
 4  10.6.62.252  14.337 ms 10.6.62.253  13.058 ms  12.865 ms
 ...
18  8.8.8.8  11.200 ms  11.046 ms  8.848 ms
```

- **Hop 1:** OVN distributed gateway router (shows destination IP due to OVN's internal TTL handling)
- **Hop 2:** `100.64.0.6` -- OVN join network (the internal link between the logical switch and the gateway router)
- **Hop 3:** `198.18.0.1` -- the bastion host, acting as the default gateway for the cluster network
- **Hop 4+:** lab network routers (`10.6.62.x`) and beyond to `8.8.8.8`

The following steps capture and examine the packet at each of these hops in detail.

### Prerequisites

Identify the pod, its IP address, the node it runs on, and its network interface index:

```bash
$ oc get pod nettools-dual-pod -n network-trace -o wide
NAME                READY   STATUS    RESTARTS   AGE   IP            NODE               NOMINATED NODE   READINESS GATES
nettools-dual-pod   2/2     Running   0          87d   10.128.2.43   m42-h32-000-r650   <none>           <none>
```

Note the key values:
- **Pod IP**: `10.128.2.43`
- **Node**: `m42-h32-000-r650`

Check the pod's eth0 interface to find the peer interface index:

```bash
$ oc exec -n network-trace nettools-dual-pod -c nettools-container-1 -- ip addr show eth0
2: eth0@if4615: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400 qdisc noqueue state UP group default
    link/ether 0a:58:0a:80:02:2b brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 10.128.2.43/23 brd 10.128.3.255 scope global eth0
       valid_lft forever preferred_lft forever
```

The `@if4615` suffix tells us the host-side veth has interface index **4615**.

Check the pod's routing table to confirm the default gateway:

```bash
$ oc exec -n network-trace nettools-dual-pod -c nettools-container-1 -- ip route
default via 10.128.2.1 dev eth0
10.128.0.0/14 via 10.128.2.1 dev eth0
10.128.2.0/23 dev eth0 proto kernel scope link src 10.128.2.43
100.64.0.0/16 via 10.128.2.1 dev eth0
172.30.0.0/16 via 10.128.2.1 dev eth0
```

All traffic to external destinations goes through the default gateway `10.128.2.1` via `eth0`.

### Step 1: Capture at Pod eth0

Start a tcpdump listener on one container while pinging from the other. Since both containers share the same network namespace, either one can capture:

```bash
# Terminal 1 - start tcpdump in container-2
$ oc exec -n network-trace nettools-dual-pod -c nettools-container-2 -- \
    tcpdump -i eth0 icmp -nn -c 2

# Terminal 2 - ping from container-1
$ oc exec -n network-trace nettools-dual-pod -c nettools-container-1 -- \
    ping -c 1 8.8.8.8
```

**Output (tcpdump):**
```
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
14:56:58.356722 IP 10.128.2.43 > 8.8.8.8: ICMP echo request, id 36, seq 1, length 64
14:56:58.367488 IP 8.8.8.8 > 10.128.2.43: ICMP echo reply, id 36, seq 1, length 64
```

**Observation:** Source IP is `10.128.2.43` (pod IP). The packet leaves the pod with its original cluster-internal address.

### Step 2: Find the Host-Side veth

From the pod's `eth0@if4615`, we know the host-side interface has index 4615. Find it on the node:

```bash
$ oc debug node/m42-h32-000-r650 -- chroot /host bash -c "ip link | grep '^4615:'"
4615: 7be093806debefd@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400 qdisc noqueue master ovs-system state UP mode DEFAULT group default
```

The host-side veth is `7be093806debefd`. Confirm which OVS bridge it belongs to:

```bash
$ oc debug node/m42-h32-000-r650 -- chroot /host bash -c "ovs-vsctl port-to-br 7be093806debefd"
br-int
```

The veth is a port on `br-int` (the integration bridge), which is the entry point into the OVS/OVN network on this node.

### Step 3: Capture at Host veth

Use `oc debug node/` to capture on host interfaces. The debug pod runs in the host network namespace and includes `tcpdump` in its default image. **Important:** do not run `chroot /host`, as that switches to the RHCOS host binaries where `tcpdump` is not installed:

```bash
# Terminal 1 - start tcpdump on the host veth (do NOT chroot /host)
$ oc debug node/m42-h32-000-r650
sh-5.1# tcpdump -i 7be093806debefd icmp -nn -c 2

# Terminal 2 - ping from the pod
$ oc exec -n network-trace nettools-dual-pod -c nettools-container-1 -- \
    ping -c 1 8.8.8.8
```

**Output (tcpdump):**
```
listening on 7be093806debefd, link-type EN10MB (Ethernet), snapshot length 262144 bytes
14:58:36.458762 IP 10.128.2.43 > 8.8.8.8: ICMP echo request, id 38, seq 1, length 64
14:58:36.477341 IP 8.8.8.8 > 10.128.2.43: ICMP echo reply, id 38, seq 1, length 64
```

**Observation:** Source IP is **still** `10.128.2.43`. The veth pair simply passes the packet between the pod network namespace and the host -- no address modification occurs here. The packet enters `br-int` with its original pod IP intact.

### Step 4: Capture at Physical NIC (SNAT Observed)

Now capture on the physical NIC `ens2f0np0`, which is a port on `br-ex`. This is where the packet exits the node toward the physical network:

```bash
# Terminal 1 - tcpdump on the physical NIC (do NOT chroot /host)
$ oc debug node/m42-h32-000-r650
sh-5.1# tcpdump -i ens2f0np0 icmp -nn -c 2

# Terminal 2 - ping from the pod
$ oc exec -n network-trace nettools-dual-pod -c nettools-container-1 -- \
    ping -c 1 8.8.8.8
```

**Output (tcpdump):**
```
listening on ens2f0np0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
14:59:26.551786 IP 198.18.0.9 > 8.8.8.8: ICMP echo request, id 40, seq 1, length 64
14:59:26.561572 IP 8.8.8.8 > 198.18.0.9: ICMP echo reply, id 40, seq 1, length 64
```

**Observation:** The source IP changed from `10.128.2.43` to `198.18.0.9`. This is the node's `br-ex` IP address. The OVN gateway router performed SNAT between `br-int` and `br-ex`, replacing the pod IP with the node IP so the packet can be routed on the cluster network.

Where does the packet go next? The worker node's routing table tells us:

```bash
$ oc debug node/m42-h32-000-r650 -- chroot /host bash -c "ip route"
default via 198.18.0.1 dev br-ex proto static
10.128.0.0/14 via 10.128.2.1 dev ovn-k8s-mp0
10.128.2.0/23 dev ovn-k8s-mp0 proto kernel scope link src 10.128.2.2
169.254.0.0/17 dev br-ex proto kernel scope link src 169.254.0.2
169.254.0.1 dev br-ex src 198.18.0.9
172.30.0.0/16 via 169.254.0.4 dev br-ex src 169.254.0.2 mtu 1400
198.18.0.0/16 dev br-ex proto kernel scope link src 198.18.0.9 metric 48
```

The destination `8.8.8.8` does not match any specific route, so it hits the **default route**: `default via 198.18.0.1 dev br-ex`. The next hop `198.18.0.1` is the bastion host (`m42-h27-000-r650`), which acts as the gateway for the `198.18.0.0/16` cluster network.

### Step 5: Verify with conntrack on the Node

The kernel's connection tracking table on the worker node records the NAT translation. Check it:

```bash
$ oc debug node/m42-h32-000-r650 -- chroot /host bash -c \
    "conntrack -L -p icmp 2>/dev/null | grep '10.128.2.43'"
```

**Output:**
```
icmp  1 28 src=10.128.2.43 dst=8.8.8.8 type=8 code=0 id=41 src=8.8.8.8 dst=198.18.0.9 type=0 code=0 id=41 mark=0
icmp  1 19 src=10.128.2.43 dst=8.8.8.8 type=8 code=0 id=40 src=8.8.8.8 dst=10.128.2.43 type=0 code=0 id=40 zone=1
```

**How to read this:** Each conntrack entry has two halves:
- **Original direction:** `src=10.128.2.43 dst=8.8.8.8` -- the pod sent a packet to 8.8.8.8
- **Reply expectation:** `src=8.8.8.8 dst=198.18.0.9` -- the reply comes back to the **node IP** (198.18.0.9), confirming SNAT is active

The `zone=1` entries track the same flow within OVN's internal connection tracking zones for de-SNAT on the return path.

### Step 6: Confirm the OVN SNAT Rule

The first SNAT is configured in OVN's Northbound database on the gateway router for this node. Query it via the `ovnkube-node` pod:

```bash
# Find the ovnkube-node pod on this node
$ oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node \
    --field-selector spec.nodeName=m42-h32-000-r650 -o name
pod/ovnkube-node-svjv4

# List NAT rules for this node's gateway router
$ oc exec -n openshift-ovn-kubernetes ovnkube-node-svjv4 -c nbdb -- \
    ovn-nbctl lr-nat-list GR_m42-h32-000-r650 | grep 10.128.2.43
```

**Output:**
```
TYPE  EXTERNAL_IP  LOGICAL_IP
snat  198.18.0.9   10.128.2.43
```

**Observation:** OVN has a per-pod SNAT rule on the gateway router `GR_m42-h32-000-r650` that maps the pod IP `10.128.2.43` to the node IP `198.18.0.9` for all egress traffic. Every pod on this node has a similar SNAT entry, all mapping to the same node IP.

This concludes the tracing on the worker node. The packet now leaves the node via `ens2f0np0` with source `198.18.0.9` and enters the `198.18.0.0/16` network toward the bastion host.

### Step 7: Capture at the Bastion Host (Second SNAT)

The cluster nodes sit on the `198.18.0.0/16` network, which is not routable to the internet. The bastion host (`m42-h27-000-r650`) acts as the gateway, with `ens2f0np0` (`198.18.0.1`) on the cluster side and `eno12399` (`10.6.62.29`) on the lab network. An iptables MASQUERADE rule performs a second SNAT as traffic exits through `eno12399`.

**Check the bastion's routing table:**

```bash
$ ssh sonali
[root@m42-h27-000-r650 ~]# ip route
default via 10.6.62.254 dev eno12399 proto dhcp src 10.6.62.29 metric 100
10.6.62.0/24 dev eno12399 proto kernel scope link src 10.6.62.29 metric 100
10.88.0.0/16 dev podman0 proto kernel scope link src 10.88.0.1
198.18.0.0/16 dev ens2f0np0 proto kernel scope link src 198.18.0.1 metric 102
```

The packet with destination `8.8.8.8` arrives on `ens2f0np0` from the cluster network. Since `8.8.8.8` does not match `198.18.0.0/16` or `10.6.62.0/24`, it hits the **default route**: `default via 10.6.62.254 dev eno12399`. The bastion forwards the packet out `eno12399` toward the lab network gateway `10.6.62.254`, applying MASQUERADE (SNAT) in the process.

**Capture on the bastion's cluster-facing NIC (`ens2f0np0`):**

```bash
$ ssh sonali
[root@m42-h27-000-r650 ~]# tcpdump -i ens2f0np0 icmp -nn -c 2
listening on ens2f0np0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
15:12:47.832179 IP 198.18.0.9 > 8.8.8.8: ICMP echo request, id 42, seq 1, length 64
15:12:47.840920 IP 8.8.8.8 > 198.18.0.9: ICMP echo reply, id 42, seq 1, length 64
```

**Observation:** The packet arrives at the bastion with source `198.18.0.9` (the node IP from the first SNAT). This is expected -- the `198.18.0.0/16` cluster network is directly connected.

**Capture on the bastion's external-facing NIC (`eno12399`):**

```bash
[root@m42-h27-000-r650 ~]# tcpdump -i eno12399 icmp -nn -c 2
listening on eno12399, link-type EN10MB (Ethernet), snapshot length 262144 bytes
15:12:57.338722 IP 10.6.62.29 > 8.8.8.8: ICMP echo request, id 43, seq 1, length 64
15:12:57.347418 IP 8.8.8.8 > 10.6.62.29: ICMP echo reply, id 43, seq 1, length 64
```

**Observation:** The source IP changed again, from `198.18.0.9` to `10.6.62.29` (the bastion's lab network IP). This is the second SNAT. The iptables MASQUERADE rule on the bastion rewrites the source for all traffic exiting `eno12399`:

```bash
[root@m42-h27-000-r650 ~]# iptables -t nat -L POSTROUTING -n -v | grep eno12399
9095K  611M MASQUERADE  0    --  *      eno12399  0.0.0.0/0            0.0.0.0/0
```

**Verify the NAT with conntrack on the bastion:**

```bash
[root@m42-h27-000-r650 ~]# conntrack -L -p icmp | grep 8.8.8.8
icmp     1 27 src=198.18.0.9 dst=8.8.8.8 type=8 code=0 id=45 src=8.8.8.8 dst=10.6.62.29 type=0 code=0 id=45 mark=0
```

**How to read this:** The original direction shows `src=198.18.0.9` (node IP) sending to `8.8.8.8`. The reply expectation shows `dst=10.6.62.29` (bastion IP), confirming the MASQUERADE rewrote the source from `198.18.0.9` to `10.6.62.29`. This is the IP address that 8.8.8.8 actually sees and replies to. The response flows back through the same path in reverse, with each NAT layer de-translating the destination IP.

### Summary

```
Capture Point                  Source IP        Destination IP   What Happened
-----------------------------  ---------------  ---------------  ----------------------------------
Pod eth0                       10.128.2.43      8.8.8.8          Original pod IP
Host veth (7be093806...)       10.128.2.43      8.8.8.8          Unchanged (veth is a pipe)
                                -- OVN Gateway Router performs SNAT #1 --
Node NIC (ens2f0np0)           198.18.0.9       8.8.8.8          Node IP (1st SNAT)
Bastion NIC (ens2f0np0)        198.18.0.9       8.8.8.8          Arrives at bastion, still node IP
                                -- iptables MASQUERADE performs SNAT #2 --
Bastion NIC (eno12399)         10.6.62.29       8.8.8.8          Bastion IP (2nd SNAT)
```

**Key Takeaways:**
- The pod IP (`10.128.2.43`) is preserved across the veth pair and within `br-int`. It is a valid, routable address only inside the cluster overlay.
- **SNAT #1** occurs at the **OVN gateway router**, which logically sits between `br-int` and `br-ex`. This replaces the pod IP with the node's `br-ex` IP (`198.18.0.9`).
- **SNAT #2** occurs at the **bastion host** via an iptables MASQUERADE rule. Since the `198.18.0.0/16` cluster network is not routable to the internet, the bastion replaces the node IP with its own lab network IP (`10.6.62.29`).
- From the internet's perspective (8.8.8.8), the packet comes from `10.6.62.29`. The return path reverses both NAT translations: the bastion de-SNATs `10.6.62.29` back to `198.18.0.9`, and the OVN gateway router de-SNATs `198.18.0.9` back to `10.128.2.43`.
- Each pod has its own SNAT entry in OVN's Northbound database (`ovn-nbctl lr-nat-list`), mapping its cluster IP to the node's external IP.

## Requirements

- OpenShift cluster
- Container runtime (Podman, Docker, or CRI-O)

## Notes

- The networking tools container requires privileged access for some operations (e.g., packet capture on host interfaces)

## References

1. [Linux interfaces](https://developers.redhat.com/blog/2018/10/22/introduction-to-linux-interfaces-for-virtual-networking)
2. [Open vSwitch](https://docs.openvswitch.org/en/latest/intro/what-is-ovs/)
3. [OVN-Kubernetes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/ovn-kubernetes_network_plugin/ovn-kubernetes-architecture-assembly#ovn-kubernetes-architecture-con)
