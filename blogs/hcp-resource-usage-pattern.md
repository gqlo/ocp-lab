Correlating QPS Rate with Resource Utilization in Self-Managed Hosted Control Planes
====================================================

## Last Updated
**Last Updated:** 2024-06-25 13:04 PM

## Introduction
The general availability of [self-managed hosted control planes](https://www.redhat.com/en/blog/unlocking-new-possibilities-general-availability-hosted-control-planes-self-managed-red-hat-openshift) (HCP) with OpenShift Virtualization (KubeVirt) is an exciting milestone. Yet, the true test lies in system performance and scalability, which are both crucial factors that determine success. Understanding and pushing these limits is essential for making informed decisions. This blog offers a comprehensive analysis and general sizing insights for consolidating existing bare metal resources using self-managed HCP with OpenShift Virtualization Provider. It delves into the resource usage patterns of the HCP, examining its relationship with KubeAPIServer QPS rate. Through various experiments, we established the linear regression model between the KubeAPI Server QPS rate and CPU/Memory/ETCD storage utilization, providing valuable insights for efficient resource consolidation and node capacity planning.

[](/media/hypershift.svg)
## Cluster Configuration
```
Cluster
│
├── Control Plane (Masters)
│   ├── master-0
│   ├── master-1
│   └── master-2
│
└── Workers
    ├── Standard Workers
    │   ├── worker000
    │   ├── worker001
    │   ├── worker002
    │    ……………………
    │   ├── worker023
    │   ├── worker024
    ├── Hosted Control Plane
    │   ├── worker003 (zone-1)
    │   ├── worker004 (zone-2)
    │   └── worker005 (zone-3)
    ├── Infra Node for Prometheus
        ├── worker025 (promdb)
        └── worker026 (promdb)
```
Kube-scheduler by default assigns pods to all schedulable nodes, often leading to HCP pods and VM worker pods co-hosting on the same node. Even the Master nodes can be made schedulable to host any pods. However, to ensure clear division of responsibilities, minimizing interference or "noise" in the cluster for clean and reliable data, we've configured the cluster topology as shown above: the management cluster includes 3 master nodes and 27 worker nodes. Specifically, three nodes (worker003-005) are dedicated to the [host control plane pods](https://github.com/stolostron/rhacm-docs/blob/2.9_stage/clusters/hosted_control_planes/hosted-cluster-workload-distributing.adoc), while two infrastructure nodes (worker025-026) support the management Prometheus pods. The remaining standard worker nodes are designated for hosting KubeVirt VMs.

## Cluster Environment
<table>
    <tr>
        <td>
            <table>
                <tr><th>Component</th><th>Version</th></tr>
                <tr><td>OCP</td><td>4.14</td></tr>
                <tr><td>CNV</td><td>4.14</td></tr>
                <tr><td>MCE</td><td>2.4</td></tr>
            </table>
        </td>
        <td>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;</td> <!-- 10 spaces -->
        <td>
            <table>
                <tr><td></td><th>CPU</th><th>RAM</th><th>Storage</th></tr>
                <tr><th>Bare Metal</th><td>64 hyperthreads</td><td>256 GiB</td><td>1TB (NVMe)</td></tr>
                <tr><th>VM Worker</th><td>8 vCPUs</td><td>32 GiB</td><td>32 GiB (PV)</td></tr>
            </table>
        </td>
    </tr>
</table>

Each bare metal node is equipped with an Intel(R) Xeon(R) Gold 6130 CPU @ 2.10GHz processor consisting of 2 sockets x 16 cores x 2 threads = 64 threads, 256 GiB of RAM spanning across two NUMA nodes and one extra 1TB of NVMe disk.

For the VM workers, 8 vCPUs, 32GiB of RAM and 32 GiB of Persistent Volume (PV) are allocated. Our sizing experiment is based on a `Highly Available (HA)` hosted cluster with 9 VM worker nodes. One VM worker node is dedicated to the guest cluster monitoring stack and benchmarking workloads are running on the remaining 8 VM workers.

## ETCD and VM Storage
To meet the latency requirements of ETCD, [LVM](https://docs.openshift.com/container-platform/4.14/storage/persistent_storage/persistent_storage_local/persistent-storage-using-lvms.html) operator is used to configure a local storage class that leverages fast NVMe devices on worker003 - worker005.

[Hostpath Provisioner](https://docs.openshift.com/container-platform/4.13/virt/virtual_machines/virtual_disks/virt-configuring-local-storage-for-vms.html) (HPP) is used for provisioning NVMe disks from standard worker nodes (worker000 - worker024, excluding HCP nodes) to back the root volumes of the VMs.

## Methodology
### Overview
CPU, Memory and ETCD storage utilization measurements were conducted for hosted clusters that were scaled across multiple dimensions, particularly focusing on the increase in KubeAPI load. To generate this API load, [Kube-burner](https://github.com/cloud-bulldozer/kube-burner) was used. This tool works by creating a multitude of objects within a namespace and then continuously churning them - that is, deleting and recreating them continuously over a period of 15 minutes.

An idle cluster, where no object creation occurs, served as the baseline for comparison. From this baseline, the experiment progressively increased the workload by creating 2, 4, and 6 namespaces, introducing a 3-minute delay between each increment. This process continued up to a total of 100 namespaces. During these 15-minute intervals, both the maximum and average data points were extracted.

This approach allowed for a detailed analysis of how the API rate correlates with resource use, providing insights into the growth relationship between increased API rate and the corresponding demand on cluster resources. This data is useful for understanding the scalability and performance characteristics of the hosted clusters under high API burst.

### Workload Profile
The workload profile is a “[cluster density](https://cloud-bulldozer.github.io/kube-burner/v1.7.9/ocp/#cluster-density-v2)” test, detailed workload used to provide this example load data can be described as follows:
* The image stream and build components were removed, to focus the utilization measurements on API/control-plane stress
* The workload creates a number of objects (configmaps, secrets, services, replicasets, deployments, routes, network policies) + 10 pods per namespace, and ramps up each iteration until 100 namespaces are created (i.e. 1,000 pods per hosted cluster)
* The “churn” value is set to 100% to cause additional API stress with continuous object deletion and creation

### Prometheus Queries
#### KubeAPI Server QPS
The QPS (Queries Per Second) and BURST parameters were set by Kube-burner on the golang client to 10,000 (QPS=10000 BURST=10000), essentially removing any limits on the client side to max out API usage. Server side QPS/BURST limit is kept at default of 1000 and 3000 for mutating and non-mutating queries respectively. The “achieved” QPS rate was queried as follows, counting all requests within the namespace, including both reads and writes.
```
sum(rate(apiserver_request_total{namespace=~"clusters-$name*"}[2m])) by (namespace)
```
#### Container CPU Usage
Since all the virt-launcher and pvc importer pods are running in the same namespace as the hosted control plane pods, we need to exclude them in our calculation.
```
sum(irate(container_cpu_usage_seconds_total{namespace=~"clusters-kv.*",container!="POD",name!="", container!="", pod!="", pod!~"virt-launcher-kv-.*|importer-kv.*"}[2m])*100) by (namespace)
```
#### Container RSS Memory
Resident set size memory is used to estimate the container memory utilization.
```
sum(container_memory_rss{namespace=~"clusters-kv.*", container!="POD", container!="", pod!="", pod!~"virt-launcher.*|importer-kv.*"}/1024/1024/1024) by (namespace)
```
### KubeAPI load VS Resource Utilization
To provide sizing insights that are more specifically tuned to the desired hosted cluster load, we studied the resource usage pattern at increasing API rates. Meaning that this scaling calculation is building in burstable resources for each hosted control plane to handle certain load points in a performant manner.

The resource scaling charts below demonstrate the observed hosted control-plane resource usage as the `achieved QPS` rate increases throughout the test, demonstrating control plane load scaling. Please note that the data plane workload itself may or may not generate a `consistent` high QPS rate.

The `solid` line in the charts represents a scaling formula using linear regression which is a good estimating factor based on measured utilization data. One can size the hosted cluster based on the detailed analysis described in the following sections.

#### Avg QPS vs. Avg CPU
<p align="center">
  <img src="/media/avg_cpu.svg">
</p>

Consider the desired hosted cluster API load when determining the amount of cpu resources that should be available for bursting. The plot above shows the linear relationship between average CPU utilization of all HCP pods and average QPS rate during each run.

The extracted data points yield a coefficient of determination (R²) value of 0.996, indicating an almost perfect fit in the linear regression line. To interpret the graph, consider a specific data point, like (600, 5). This means that with an average request rate of 600 queries handled by all KubeAPI servers over 15 minutes, the average CPU consumption should be around 5 vCPUs.

The equation displayed on the plot can be used to predict average CPU consumption based on the average QPS input variable x, with a theoretical maximum of 3000 * 3. Beyond this point, kubeAPI servers are likely to start throttling, preventing uncontrolled growth in resource consumption.

The example utilization scaling above is based on the average CPU usage of each Hosted Control Plane throughout the workload run. However, CPU usage spikes can vary up to ~2x higher than the average, consider factoring in extra cpu resources per cluster if some cpu overcommit is not desired.

#### Max QPS vs. Max CPU
<p align="center">
  <img src="/media/max_cpu.svg">
</p>

Modeling the relationship between maximum CPU utilization of HCP pods and the maximum QPS rate can be tricky due to periodical CPU spikes from events like catalog pod dumps, which aren't directly triggered by QPS bursts. Despite this, the linear regression line for max CPU consumption has a coefficient of determination value of 0.931. Although slightly lower, it still provides a solid fit and reliable estimates for maximum CPU consumption during QPS bursts.

#### Avg QPS vs. Avg Memory
<p align="center">
  <img src="/media/avg_mem.svg">

The default memory request for each hosted control plane is approximately 18 GiB. Observations show that hosted control plane pods typically consume around 15 GiB of RAM at an average QPS rate of 1000. This generous memory allocation for requests likely aims to prevent Out Of Memory (OOM) conditions.

#### Max QPS vs. Max Memory
<p align="center">
  <img src="/media/max_mem.svg">

Maximum QPS (Queries Per Second) rate versus maximum memory utilization in the hosted control plane pods follows a trend similar to that observed in the average QPS rate plot. Even when the QPS rate spiked to 2000, there was no significant increase in the memory consumption of the hosted control plane pods. This indicates that the memory utilization has been fairly consistent, even under conditions of high query load.

### ETCD DB Scaling
<p align="center">
  <img src="/media/etcd_db.svg">

The ETCD database size expands with the increasing number of pods and related objects such as configmaps and secrets. Under the previously described workload profile, the linear regression line indicates that the database could remain within the default 8 GiB PVC size limit until it reaches roughly 11k pods and associated objects without defragmentation.

## Caveats
The workload profile being discussed is entirely simulated using the Kube-burner benchmark tool. This tool is designed to create conditions in a controlled environment that may not typically occur in a real-world production scenario. Specifically, the high API burst rate generated is likely less common than what one would normally encounter in a production environment. Despite this, it is still valuable for understanding the performance and scaling limits, identifying bottlenecks of the cluster.

## Summary
This blog provides a detailed analysis of resource usage patterns in hosted control planes, establishing the relationship between API rate and CPU/memory utilization, and offers insights on node capacity to aid customers in making informed decisions.

For general sizing guidance regarding request size, pod limits and more please check out host control plane [sizing guidance documentation](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/2.9/html/clusters/cluster_mce_overview#hosted-sizing-guidance).

## Future Work
In our upcoming work, we aim to focus on deploying realistic workloads, potentially using ArgoCD, to better simulate real-world scenarios and enhance our understanding of HCP resource usage patterns.

## Acknowledgment
I extend my sincere gratitude to Michey Mehta for his contribution in data analysis and  technical input and to Jenifer Abrams for her leadership and substantial contribution on the sizing guidance document, which significantly shaped this blog. Additionally, my appreciation goes out to the entire OpenShift Virtualization Performance & Scale team for their consistent and insightful contributions throughout this process. Their collective efforts have been invaluable and are deeply appreciated.

