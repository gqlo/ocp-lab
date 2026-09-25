#!/bin/bash
hname=$(hostname)
{
mkdir -p /root/fio-output/
sudo rm -rf /root/fio-output/randwrite-$hname-$batch_num.txt /root/fio-output/fio-"$hname"-"$batch_num".log
echo "batch-$batch_num fio started $(date +"%Y-%m-%d %H:%M:%S")"
sudo rm -rf /root/rhel9* 
fio --name=$hname --ioengine=libaio --rw=randwrite --bs=4k --direct=1 --numjobs=1 --size=8G --runtime=30m  --iodepth=256 --output=/root/fio-output/randwrite-$hname-$batch_num.txt 
sudo rm -rf /root/rhel9* 
sleep 120
fio --name=$hname --ioengine=libaio --rw=randread --bs=4k --direct=1 --numjobs=1 --size=8G --runtime=30m  --iodepth=256 --output=/root/fio-output/randread-$hname-$batch_num.txt 
sudo rm -rf /root/rhel9* 
sleep 120
fio --name=$hname --ioengine=libaio --rw=randrw --bs=4k --direct=1 --numjobs=1 --size=8G --runtime=30m  --iodepth=256 --output=/root/fio-output/randrw-$hname-$batch_num.txt 
echo "batch-$batch_num fio ended $(date +"%Y-%m-%d %H:%M:%S")"
sudo rm -rf /root/rhel9* 
}  2>&1 | tee -a /root/fio-output/fio-"$hname"-"$batch_num".log
