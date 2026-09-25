A close look at k8s networking model
===========================================================
## Last Updated
**Last Updated:** 2024-06-25 13:04 PM

## Introduction
This document covers the detailed data flow from a service endpoint request down to the pod network interface. It includes the detailed tracing of how packet flows within k8s environment where OVN is used. The expirement was done on a single node openshift cluster environment running within a VM. 
## Cluster environment
We have a single node openshift cluster running within a QEMU/KVM VM. 
```
oc get nodes
NAME                STATUS   ROLES                         AGE   VERSION
52-54-00-a7-93-9c   Ready    control-plane,master,worker   27h   v1.28.9+8ca71f7

```
### VM config
The VM is called sno, assigned with an IP address 192.168.122.237/24
```
sudo virsh list
 Id   Name   State
----------------------
 4    sno    running
```

```
sudo virsh domifaddr sno
 Name       MAC address          Protocol     Address
-------------------------------------------------------------------------------
 vnet3      52:54:00:a7:93:9c    ipv4         192.168.122.237/24

```
### Host config
virbr0 which is a virtual bridge interface created by libvirt for NAT(Network Address Translation).
```
8: virbr0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether 52:54:00:62:66:de brd ff:ff:ff:ff:ff:ff
    inet 192.168.122.1/24 brd 192.168.122.255 scope global virbr0
       valid_lft forever preferred_lft forever
```
### HTTP service
A sample web application is deployed 
```
oc get all -n demo-sno
NAME                                READY   STATUS      RESTARTS   AGE
pod/httpd-ex-git-1-build            0/1     Completed   0          26h
pod/httpd-ex-git-769765ffd5-frlp8   1/1     Running     0          26h

NAME                   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)             AGE
service/httpd-ex-git   ClusterIP   172.30.95.17   <none>        8080/TCP,8443/TCP   26h

NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/httpd-ex-git   1/1     1            1           26h

NAME                                      DESIRED   CURRENT   READY   AGE
replicaset.apps/httpd-ex-git-769765ffd5   1         1         1       26h

NAME                                          TYPE     FROM   LATEST
buildconfig.build.openshift.io/httpd-ex-git   Source   Git    1

NAME                                      TYPE     FROM          STATUS     STARTED        DURATION
build.build.openshift.io/httpd-ex-git-1   Source   Git@6dd8df4   Complete   26 hours ago   32s

NAME                                          IMAGE REPOSITORY                                                         TAGS     UPDATED
imagestream.image.openshift.io/httpd-ex-git   image-registry.openshift-image-registry.svc:5000/demo-sno/httpd-ex-git   latest   26 hours ago

NAME                                    HOST/PORT                                    PATH   SERVICES       PORT       TERMINATION     WILDCARD
route.route.openshift.io/httpd-ex-git   httpd-ex-git-demo-sno.apps.sno.example.com          httpd-ex-git   8080-tcp   edge/Redirect   None
```
All the urls are pointing the a same IP address in /etc/hosts file.
```
# sno
192.168.122.237 console-openshift-console.apps.sno.example.com
192.168.122.237 api.sno.example.com
192.168.122.237 oauth-openshift.apps.sno.example.com
192.168.122.237 downloads-openshift-console.apps.sno.example.com
192.168.122.237 canary-openshift-ingress-canary.apps.sno.example.com
192.168.122.237 httpd-ex-git-demo-sno.apps.sno.example.com
```
```
getent hosts httpd-ex-git-demo-sno.apps.sno.example.com
192.168.122.237 httpd-ex-git-demo-sno.apps.sno.example.com
```
curling the service endpoint
```
curl -L -k httpd-ex-git-demo-sno.apps.sno.example.com
sno http test page
```
We have many URLs pointing to the same IP address, so how does the incoming/outgoing request know where the packets should be sent to? NAT is not applicable here since all URLs sharing the same IP address on port 80. By looking inside of the SNO node (VM), haproxy is listening all avaialble IPv4 address on port 80. See an article on [haproxy loadbalancing](https://www.digitalocean.com/community/tutorials/an-introduction-to-haproxy-and-load-balancing-concepts)

```
netstat -lntp | grep :80
tcp        0      0 0.0.0.0:80              0.0.0.0:*               LISTEN      1371721/haproxy      │tcp        0      0 0.0.0.0:80              0.0.0.0:*               LISTEN      1371721/haproxy 
```
haproxy is also listening on port 443 which is the standard port for HTTPS.
```
netstat -lntp | grep haproxy
tcp        0      0 0.0.0.0:443             0.0.0.0:*               LISTEN      1371721/haproxy     
tcp        0      0 0.0.0.0:80              0.0.0.0:*               LISTEN      1371721/haproxy
```
haproxy is able to forward the request using layer 7 load balancing to the corresponding service, in our case, httpd-ex-git under demo-sno namespace.
```
oc get route -n demo-sno
NAME           HOST/PORT                                    PATH   SERVICES       PORT       TERMINATION     WILDCARD
httpd-ex-git   httpd-ex-git-demo-sno.apps.sno.example.com          httpd-ex-git   8080-tcp   edge/Redirect   None
```

This http service is listening on TCP port 8080/8443 at address 172.30.95.17.
```
oc get service -n demo-sno
NAME           TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)             AGE
httpd-ex-git   ClusterIP   172.30.95.17   <none>        8080/TCP,8443/TCP   45h
```

Let's take a closer look at this service:
```
oc describe service httpd-ex-git -n demo-sno
Name:              httpd-ex-git
Namespace:         demo-sno
Labels:            app=httpd-ex-git
                   app.kubernetes.io/component=httpd-ex-git
                   app.kubernetes.io/instance=httpd-ex-git
                   app.kubernetes.io/name=httpd-ex-git
                   app.kubernetes.io/part-of=httpd-ex-git-app
                   app.openshift.io/runtime=httpd
                   app.openshift.io/runtime-version=latest
Annotations:       app.openshift.io/vcs-ref: 
                   app.openshift.io/vcs-uri: https://github.com/sclorg/httpd-ex.git
                   openshift.io/generated-by: OpenShiftWebConsole
Selector:          app=httpd-ex-git,deployment=httpd-ex-git
Type:              ClusterIP
IP Family Policy:  SingleStack
IP Families:       IPv4
IP:                172.30.95.17
IPs:               172.30.95.17
Port:              8080-tcp  8080/TCP
TargetPort:        8080/TCP
Endpoints:         10.128.0.81:8080
Port:              8443-tcp  8443/TCP
TargetPort:        8443/TCP
Endpoints:         10.128.0.81:8443
Session Affinity:  None
Events:            <none>
```
This yaml tells us the service port to pod port mapping which are 8080 -> 8080 and 8443 -> 8443. The end point which is the pod IP is assigned as 10.128.0.81. Here is when OVN takes into play, making all the port mapping and request forwarding possible.

Let's take a look at OVN pods. Since it's a single node cluster, both the ovn control plane and the node daemon are running on the same node. Note that, both pods are assigned with the IP address of 192.168.122.237. 
```
oc get pod -o wide -n openshift-ovn-kubernetes
NAME                                     READY   STATUS    RESTARTS   AGE   IP                NODE                NOMINATED NODE   READINESS GATES
ovnkube-control-plane-78b4b5979b-9lxlw   2/2     Running   4          23d   192.168.122.237   52-54-00-a7-93-9c   <none>           <none>
ovnkube-node-j48k2                       8/8     Running   18         23d   192.168.122.237   52-54-00-a7-93-9c   <none>           <none>
```

By looking at the load balancing list, we can see that service IP 172.30.95.17 is mapped to 10.128.0.81 on port 8080 and 8443. Since our demo project has only pod pod deployment, we are only seeing the loadbalaner mapping to a single IP address.
```
oc exec -n openshift-ovn-kubernetes ovnkube-node-j48k2 -- ovn-nbctl lb-list | grep 172.30.95.17
Defaulted container "ovn-controller" out of: ovn-controller, ovn-acl-logging, kube-rbac-proxy-node, kube-rbac-proxy-ovn-metrics, northd, nbdb, sbdb, ovnkube-controller, kubecfg-setup (init)
8a65e790-0399-4f0f-8020-7dc4e57d371d    Service_demo-sno    tcp        172.30.95.17:8080       10.128.0.81:8080
                                                            tcp        172.30.95.17:8443       10.128.0.81:8443
```
Let's scale up our pod count to 2 and see how it looks like:

```
oc scale --replicas=2 deployment.apps/httpd-ex-git -n demo-sno
deployment.apps/httpd-ex-git scaled
```
We are have two replicas.
```
oc get pod -n demo-sno
NAME                            READY   STATUS      RESTARTS   AGE
httpd-ex-git-1-build            0/1     Completed   0          46h
httpd-ex-git-769765ffd5-frlp8   1/1     Running     0          46h
httpd-ex-git-769765ffd5-sb5zs   1/1     Running     0          38s
```
Without suprise, OVN is now load banlancing the requests on two pods with two different IP addresses.
```
oc exec -n openshift-ovn-kubernetes ovnkube-node-j48k2 -- ovn-nbctl lb-list | grep 172.30.95.17
Defaulted container "ovn-controller" out of: ovn-controller, ovn-acl-logging, kube-rbac-proxy-node, kube-rbac-proxy-ovn-metrics, northd, nbdb, sbdb, ovnkube-controller, kubecfg-setup (init)
8a65e790-0399-4f0f-8020-7dc4e57d371d    Service_demo-sno    tcp        172.30.95.17:8080       10.128.0.81:8080,10.128.1.99:8080
                                                            tcp        172.30.95.17:8443       10.128.0.81:8443,10.128.1.99:8443
```
Let's use tcpdump to actually trace the packet flow and to verify our understanding. Let's get into the node and start a tcpdump session. You may notice that tcpdump does come with coreos by default, however, we can use this handy tool called toolbox which have packed commonly used tools for debugging including dnf. 

before that, let's scale down the deployment to 1, so our tcpdump session will be more deterministic. 

```
oc scale --replicas=1 deployment.apps/httpd-ex-git -n demo-sno
deployment.apps/httpd-ex-git scaled
```

```
oc get pod -n demo-sno
NAME                            READY   STATUS      RESTARTS   AGE
httpd-ex-git-1-build            0/1     Completed   0          47h
httpd-ex-git-769765ffd5-frlp8   1/1     Running     0          47h
```
We can find out the actual container id running on the host using crictl tool which requires us to use the host binary by doing chroot /host

```
sh-5.1# crictl pods --namespace demo-sno --name httpd-ex-git-769765ffd5-frlp8 -q
6a0f2d307f4fa4af097705a652a3abf5ae9042d6209bf533e4d73d5d66610475
```
The pod ID we are interested is 6a0f2d307f4fa, we can inspect its content by:

```
crictl inspectp 6a0f2d307f4fa4af097705a652a3abf5ae9042d6209bf533e4d73d5d66610475 | grep -A3 network
    "network": {
      "additionalIps": [],
      "ip": "10.128.0.81"
    },
--
          "network": "POD",
          "pid": "CONTAINER",
          "targetId": "",
          "usernsOptions": null
--
            "type": "network",
            "path": "/var/run/netns/6a52c837-2ff1-4832-aa01-055d41d95b3d"
          },
          {
```
We are only interested in the network namespace so later we can enter that namespace find the network interface of that particular container. From the output above, we found the network namespace of that particular container, we can enter that namespace by:
```
nsenter --net=/host//var/run/netns/6a52c837-2ff1-4832-aa01-055d41d95b3d
```
To confirm we are in the right place:
```
[root@52-54-00-a7-93-9c /]# ip a
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host 
       valid_lft forever preferred_lft forever
2: eth0@if106: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400 qdisc noqueue state UP group default 
    link/ether 0a:58:0a:80:00:51 brd ff:ff:ff:ff:ff:ff link-netns 4a15dff6-6f1d-421f-8599-1b8b9f62ede4
    inet 10.128.0.81/23 brd 10.128.1.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::858:aff:fe80:51/64 scope link 
       valid_lft forever preferred_lft forever
```
After confirmed that we are in the right place, let's start a TCP dump session listening to the particular TCP port 8080:
```
tcpdump -i eth0 -nn tcp port 8080
dropped privs to tcpdump
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
```
then we can curl the service endpoint from the host:
```
curl -L -k httpd-ex-git-demo-sno.apps.sno.example.com
```
Here is the full tcpdump within the container:
```
tcpdump -i eth0 -nn tcp port 8080
dropped privs to tcpdump
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
1.  06:43:20.251037 IP 10.128.0.2.58884 > 10.128.0.81.8080: Flags [S], seq 652481145, win 65280, options [mss 1360,sackOK,TS val 899985808 ecr 0,nop,wscale 7], length 0
2.  06:43:20.251101 IP 10.128.0.81.8080 > 10.128.0.2.58884: Flags [S.], seq 440466640, ack 652481146, win 64704, options [mss 1360,sackOK,TS val 1638289445 ecr 899985808,nop,wscale 7], length 0
3.  06:43:20.251576 IP 10.128.0.2.58884 > 10.128.0.81.8080: Flags [.], ack 1, win 510, options [nop,nop,TS val 899985809 ecr 1638289445], length 0
4.  06:43:20.251676 IP 10.128.0.2.58884 > 10.128.0.81.8080: Flags [P.], seq 1:339, ack 1, win 510, options [nop,nop,TS val 899985809 ecr 1638289445], length 338: HTTP: GET / HTTP/1.1
5.  06:43:20.251697 IP 10.128.0.81.8080 > 10.128.0.2.58884: Flags [.], ack 339, win 503, options [nop,nop,TS val 1638289446 ecr 899985809], length 0
6.  06:43:20.276392 IP 10.128.0.81.8080 > 10.128.0.2.58884: Flags [P.], seq 1:295, ack 339, win 503, options [nop,nop,TS val 1638289470 ecr 899985809], length 294: HTTP: HTTP/1.1 200 OK
7.  06:43:20.276517 IP 10.128.0.2.58884 > 10.128.0.81.8080: Flags [.], ack 295, win 508, options [nop,nop,TS val 899985834 ecr 1638289470], length 0
8.  06:43:25.280762 IP 10.128.0.81.8080 > 10.128.0.2.58884: Flags [F.], seq 295, ack 339, win 503, options [nop,nop,TS val 1638294475 ecr 899985834], length 0
9.  06:43:25.280915 IP 10.128.0.2.58884 > 10.128.0.81.8080: Flags [F.], seq 339, ack 296, win 508, options [nop,nop,TS val 899990839 ecr 1638294475], length 0
10. 06:43:25.280946 IP 10.128.0.81.8080 > 10.128.0.2.58884: Flags [.], ack 340, win 503, options [nop,nop,TS val 1638294475 ecr 899990839], length 0
```
This tcpdump demonstrates a perfect example of TCP [3 way Handshake](https://www.geeksforgeeks.org/tcp-3-way-handshake-process/) and how HTTP request is handled. See a [list of tcpdump flags](https://amits-notes.readthedocs.io/en/latest/networking/tcpdump.html) and its meaning. 
1. Client send SYN to establish communication 
2. SYN + ACK response from server 
3. Client ACK the reliable connection is established. 
4. HTTP GET request is sent from client
5. Server ACK the HTTP GET request 
6. HTTP Response 200 OK reponse sent from server
7. Client ACK the HTTP response 
8. FIN indicates server wants to terminate the connection 
9. Client response to terminate the connection 
10. Server send ACK reponse to complete the connection.

But we are curling service endpoint which has the IP of "192.168.122.237", apparentlly there is something in between. So what is this IP "10.128.0.2". Let's find it out.



