FROM registry.access.redhat.com/ubi9:9.8
RUN dnf install --disablerepo='*' --enablerepo=rhel-9-for-x86_64-baseos-eus-rpms --enablerepo=rhel-9-for-x86_64-appstream-eus-rpms --releasever=9.8 \
        sysstat -y 
# Install OCP node version of kernel-core and kernel-headers      
RUN dnf install --disablerepo='*' --enablerepo=rhel-9-for-x86_64-baseos-eus-rpms --enablerepo=rhel-9-for-x86_64-appstream-eus-rpms --releasever=9.8 \
        kernel-core-5.14.0-687.11.1.el9_8.x86_64 kernel-headers-5.14.0-687.11.1.el9_8.x86_64 -y
# Install bpftrace and bpftool, and their dependencies (bcc, python-bcc)
RUN dnf install --disablerepo='*' --enablerepo=rhel-9-for-x86_64-baseos-eus-rpms --enablerepo=rhel-9-for-x86_64-appstream-eus-rpms --releasever=9.8 \
        bpftrace bpftool -y
RUN dnf clean all
