virt-install --name rhel93 --ram 8196 --vcpus 16 --cdrom  /root/cnv/RHEL-9.3.0-20231025.65-x86_64-dvd1.iso --disk path=/root/cnv/rhel93.img, bus=virtio --network bridge=br0 --vnc
