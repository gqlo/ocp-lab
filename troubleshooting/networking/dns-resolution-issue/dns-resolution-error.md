# Debugging DNS resolution issue: Unable to Connect to Prometheus Endpoint

## Overview

My colleague ran into an issue where the Grafana dashboard is not able to connect to the Prometheus service due to a DNS resolution related error. This turned out to be a really good exercise, where we can apply what we have been doing on network tracing in OCP to a real debugging case.

## Environment Details

- **Namespace**: `dittybopper`
- **Grafana Pod**: `dittybopper-79954578d9-44zs7` (IP: `10.128.3.187`)
- **Grafana Renderer Pod**: `grafana-renderer-684d95697-mk7xv` (IP: `10.128.3.186`)
- **Node**: `m42-h32-000-r650` (Host IP: `198.18.0.9`)
- **CNI**: OVN-Kubernetes
- **Network Gateway**: `10.128.2.1`

## Step-by-Step Debugging Process
### Error message 
```
{
    "results": {
        "test": {
            "error": "Get \"https://prometheus-k8s.openshift-monitoring.svc.cluster.local:9091/api/v1/query?query=1%2B1&time=1769108773.222\": dial tcp: lookup prometheus-k8s.openshift-monitoring.svc.cluster.local: no such host",
            "status": 500
        }
    }
}
```
`dial tcp: lookup <hostname>: no such host` is a standard error message return by Go net package when there is something wrong with resolving a hostname, suggesting a DNS resolution related error. 

### Test the DNS resolution directly within Grafana pod
The interesting thing is that when we use nslookup to test this hostname within the Grafana pod, it is able to resolve to the IP address. This is odd, but also reassuring that our DNS server is at least accepting queries and responding us with the correct IP address. 
```
14:34:17 guoqingli@rh:~$ oc rsh -n dittybopper dittybopper-5ffb885bc9-z77ll
Defaulted container "dittybopper" out of: dittybopper, dittybopper-syncer
/usr/share/grafana $ nslookup prometheus-k8s.openshift-monitoring.svc.cluster.local
Server:		172.30.0.10
Address:	172.30.0.10:53


Name:	prometheus-k8s.openshift-monitoring.svc.cluster.local
Address: 172.30.31.13

/usr/share/grafana $ 
```
### DNS packet tracing
To get a better picture of what's going on, I decided to trace the DNS packet within the Grafana pod namespace to see what's exactly being sent to the DNS server. One way to do that is to find the container ID and then the process ID of that container using crictl. The trick here is that OCP host binaries do not include the tcpdump tool. Luckily, the debug pod image contains tcpdump. We need to extract the container PID first, then exit the chroot session back to the debug container so that we can use tcpdump.

```
15:43:36 guoqingli@rh:~$ oc debug node/m42-h31-000-r650
Temporary namespace openshift-debug-qbvz2 is created for debugging node...
Starting pod/m42-h31-000-r650-debug-h7h9r ...
To use host binaries, run `chroot /host`
Pod IP: 198.18.0.8
If you don't see a command prompt, try pressing enter.
sh-5.1# chroot /host
sh-5.1# POD_NAME=dittybopper-5cb7fd8d77-g8xbc
sh-5.1# CONTAINER_ID=$(crictl ps | grep $POD_NAME | grep dittybopper | awk '{print $1}')
sh-5.1# echo $CONTAINER_ID  
aa8484521192a b7c9b2bcb7812
sh-5.1# PID=$(crictl inspect $CONTAINER_ID | grep pid | head -1 | awk '{print $2}' | tr -d ',')
sh-5.1# echo $PID
1072048
sh-5.1# exit
exit
sh-5.1# PID=1072048
sh-5.1# nsenter -t $PID -n tcpdump -i any -n port 53
tcpdump: data link type LINUX_SLL2
dropped privs to tcpdump
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on any, link-type LINUX_SLL2 (Linux cooked v2), snapshot length 262144 bytes
```

Then I went to the grafana web UI, tested the promethues database connection, I am seeing those logs.
```
listening on any, link-type LINUX_SLL2 (Linux cooked v2), snapshot length 262144 bytes
20:45:55.746113 eth0  Out IP 10.131.0.45.45557 > 172.30.0.10.domain: 8708+ A? prometheus-k8s.openshift-monitoring.svc.cluster.local.dittybopper.svc.cluster.local. (101)
20:45:55.746204 eth0  Out IP 10.131.0.45.45557 > 172.30.0.10.domain: 9731+ AAAA? prometheus-k8s.openshift-monitoring.svc.cluster.local.dittybopper.svc.cluster.local. (101)
20:45:55.750755 eth0  In  IP 172.30.0.10.domain > 10.131.0.45.45557: 9731 NXDomain*- 0/1/0 (194)
20:45:55.750798 eth0  In  IP 172.30.0.10.domain > 10.131.0.45.45557: 8708 NXDomain*- 0/1/0 (194)
20:45:55.751034 eth0  Out IP 10.131.0.45.54066 > 172.30.0.10.domain: 20362+ A? prometheus-k8s.openshift-monitoring.svc.cluster.local.svc.cluster.local. (89)
20:45:55.751136 eth0  Out IP 10.131.0.45.54066 > 172.30.0.10.domain: 21610+ AAAA? prometheus-k8s.openshift-monitoring.svc.cluster.local.svc.cluster.local. (89)
20:45:55.751965 eth0  In  IP 172.30.0.10.domain > 10.131.0.45.54066: 21610 NXDomain*- 0/1/0 (182)
20:45:55.752048 eth0  In  IP 172.30.0.10.domain > 10.131.0.45.54066: 20362 NXDomain*- 0/1/0 (182)
20:45:55.752233 eth0  Out IP 10.131.0.45.45713 > 172.30.0.10.domain: 10106+ A? prometheus-k8s.openshift-monitoring.svc.cluster.local.cluster.local. (85)
20:45:55.752327 eth0  Out IP 10.131.0.45.45713 > 172.30.0.10.domain: 11204+ AAAA? prometheus-k8s.openshift-monitoring.svc.cluster.local.cluster.local. (85)
20:45:55.753162 eth0  In  IP 172.30.0.10.domain > 10.131.0.45.45713: 11204 NXDomain*- 0/1/0 (178)
20:45:55.753280 eth0  In  IP 172.30.0.10.domain > 10.131.0.45.45713: 10106 NXDomain*- 0/1/0 (178)
20:45:55.753408 eth0  Out IP 10.131.0.45.42711 > 172.30.0.10.domain: 6168+ A? prometheus-k8s.openshift-monitoring.svc.cluster.local.mno.example.com. (87)
20:45:55.753502 eth0  Out IP 10.131.0.45.42711 > 172.30.0.10.domain: 7309+ AAAA? prometheus-k8s.openshift-monitoring.svc.cluster.local.mno.example.com. (87)
20:45:55.760768 eth0  In  IP 172.30.0.10.domain > 10.131.0.45.42711: 6168 0/0/0 (87)
20:45:55.760897 eth0  In  IP 172.30.0.10.domain > 10.131.0.45.42711: 7309 0/0/0 (87)
20:45:55.857814 eth0  Out IP 10.131.0.45.57322 > 172.30.0.10.domain: 63077+ A? prometheus-k8s.openshift-monitoring.svc.cluster.local.dittybopper.svc.cluster.local. (101)
20:45:55.857917 eth0  Out IP 10.131.0.45.57322 > 172.30.0.10.domain: 64088+ AAAA? prometheus-k8s.openshift-monitoring.svc.cluster.local.dittybopper.svc.cluster.local. (101)
20:45:55.858693 eth0  In  IP 172.30.0.10.domain > 10.131.0.45.57322: 64088 NXDomain*- 0/1/0 (194)
20:45:55.858791 eth0  In  IP 172.30.0.10.domain > 10.131.0.45.57322: 63077 NXDomain*- 0/1/0 (194)
20:45:55.858893 eth0  Out IP 10.131.0.45.58461 > 172.30.0.10.domain: 57249+ A? prometheus-k8s.openshift-monitoring.svc.cluster.local.svc.cluster.local. (89)
20:45:55.859008 eth0  Out IP 10.131.0.45.58461 > 172.30.0.10.domain: 58293+ AAAA? prometheus-k8s.openshift-monitoring.svc.cluster.local.svc.cluster.local. (89)
20:45:55.859793 eth0  In  IP 172.30.0.10.domain > 10.131.0.45.58461: 58293 NXDomain*- 0/1/0 (182)
20:45:55.859892 eth0  In  IP 172.30.0.10.domain > 10.131.0.45.58461: 57249 NXDomain*- 0/1/0 (182)
20:45:55.860022 eth0  Out IP 10.131.0.45.56830 > 172.30.0.10.domain: 2457+ A? prometheus-k8s.openshift-monitoring.svc.cluster.local.cluster.local. (85)
20:45:55.860109 eth0  Out IP 10.131.0.45.56830 > 172.30.0.10.domain: 3479+ AAAA? prometheus-k8s.openshift-monitoring.svc.cluster.local.cluster.local. (85)
20:45:55.860851 eth0  In  IP 172.30.0.10.domain > 10.131.0.45.56830: 3479 NXDomain*- 0/1/0 (178)
20:45:55.860975 eth0  In  IP 172.30.0.10.domain > 10.131.0.45.56830: 2457 NXDomain*- 0/1/0 (178)
20:45:55.861087 eth0  Out IP 10.131.0.45.36638 > 172.30.0.10.domain: 24703+ A? prometheus-k8s.openshift-monitoring.svc.cluster.local.mno.example.com. (87)
20:45:55.861172 eth0  Out IP 10.131.0.45.36638 > 172.30.0.10.domain: 25814+ AAAA? prometheus-k8s.openshift-monitoring.svc.cluster.local.mno.example.com. (87)
20:45:55.861825 eth0  In  IP 172.30.0.10.domain > 10.131.0.45.36638: 24703* 0/0/0 (174)
```

### Understanding /etc/resolv.conf
Before analyzing the logs, we should probably understand what the resolv.conf file does.

The `/etc/resolv.conf` file configures DNS resolution inside the container. 

```
/usr/share/grafana $ cat /etc/resolv.conf 
search dittybopper.svc.cluster.local svc.cluster.local cluster.local mno.example.com
nameserver 172.30.0.10
options ndots:5
```

**How to interpret this file:**

- **`search`**: DNS search domains. When resolving a hostname, the system tries appending each domain in order:
  - `prometheus-k8s` → tries `prometheus-k8s.dittybopper.svc.cluster.local` first
  - If not found → tries `prometheus-k8s.svc.cluster.local`
  - If not found → tries `prometheus-k8s.cluster.local`
  - If not found → tries `prometheus-k8s.mno.example.com`
  
- **`nameserver 172.30.0.10`**: The DNS server IP (CoreDNS/kube-dns). All DNS queries go to this address.

- **`options ndots:5`**: If a hostname has 5 or more dots (`.`), it's treated as a FQDN and searched directly. Otherwise, search domains are appended first.
  - `prometheus-k8s.openshift-monitoring.svc.cluster.local` (3 dots) → treated as relative, search domains appended first
  - `prometheus-k8s.openshift-monitoring.svc.cluster.local.` (4 dots + trailing dot) → treated as absolute FQDN, no search domains

So basically, if a hostname has less than equal 5 dots, it will append those search domains before tring the orginal hostname. If we go back and take a look at the DNS packets logs, we observed that the 4th DNS query came back with a success response (0/0/0) but empty record. 
```
20:45:55.760768 eth0  In  IP 172.30.0.10.domain > 10.131.0.45.42711: 6168 0/0/0 (87)
20:45:55.760897 eth0  In  IP 172.30.0.10.domain > 10.131.0.45.42711: 7309 0/0/0 (87)
```
As a result, the original hostname DNS query were never sent out.We current have two workarounds:
- change the ndots to be less than or equal 4, so the promethues db URL will be treated as a full FQDN without appening those search domains, which also puts less load on the dnsserver.
- When deloying dittyboper pods, instead of using the full promethues API URL, we could just use the service name and take advantage of the resolve.conf to append the search domains.

The root cause of this is still unclear, we suspect it might has to do with the upstream DNS resolver. More debugging need to be continued.. 