Understanding Kernel /proc/diskstats 
===========================================================
## Last Updated
**Last Updated:** 2024-06-25 13:04 PM

## Introduction
proc virtual filesystem contains a hierarchy of specical files that represent the current state of the kernel, running processes and hardware details. Disk I/O related statistics exposed by Promethues come from the kernel raw stats [/proc/diskstats](https://www.kernel.org/doc/Documentation/admin-guide/iostats.rst). I did a few expirements using dd utility to understand how kernel counts a write/read requests to the actual device.
## stats field 
I have a NVMe disk on this machine and root fielsystem installed on a seperate disk. So it is pretty isolated, we should get fairly accurate measurement without any nosie.
```
cat /proc/diskstats  | grep nvme
 259       0 nvme0n1 740953 0 10085328 22982 29145 679961 5672848 1955 0 42097 24938 0 0 0 0
```
The first 3 fields are used for device identification (major, minior device number and the device name). To measure how writes are counted, we are interested in 8th and 9th fileds which coressponding to "number of writes and mereged completed". I wrotea adhoc script using dd to write directly to the block device.
## dd script
```
#! /bin/bash
bs=4k
echo "written, merged, write-diff, merged-diff"
for ((c=1; c<=128; c=c*2)); do
   read prev_writes prev_wr_mreged < <(cat /proc/diskstats | grep nvme | awk '{print $8, $9}')
   dd if=/dev/urandom of=/dev/nvme0n1 bs=$bs count=$c &> /dev/null
   sleep 1
   bs_num=${bs%?}
   read curr_write curr_wr_mreged < <(cat /proc/diskstats | grep nvme | awk '{print $8, $9}')
   echo "$((c * bs_num))k, $curr_write, $curr_wr_mreged, $((curr_write - prev_writes)), $((curr_wr_mreged - prev_wr_mreged))" 
done
```
## Analysis
As we can see from the stats below, for any block size less or equal than 128k, the kernel is able to complete the write in a single request.
```
written, merged, write-diff, merged-diff
4k, 29290, 681646, 1, 0
8k, 29291, 681647, 1, 1
16k, 29292, 681650, 1, 3
32k, 29293, 681657, 1, 7
64k, 29294, 681672, 1, 15
128k, 29295, 681703, 1, 31
256k, 29297, 681765, 2, 62
512k, 29301, 681889, 4, 124
```
From the merged diff field, we can see that for any block size greater than 4k, merge happens. It tries to merge one 4k request with another 4k. The maximum single request size seems to be 128k as we can see starting from 128k, the actualy compeleted write requests is greater than 2 and a factor of 128k. 128k is the [max_hw_sectors_kb](https://www.kernel.org/doc/Documentation/block/queue-sysfs.txt) size which is the maximum number of kilobytes supported in a single data transfer. This explains why there is only one request needed when the data size is less than 128k.

```
cat /sys/block/nvme0n1/queue/max_hw_sectors_kb
128
```
Whereas in ceph, the max_hw_sectors_kb size is set to be 4096K, any data size that's less than that will be counted as one request in ceph metrics.
```
cat /sys/block/rbd0/queue/max_hw_sectors_kb
4096
```
