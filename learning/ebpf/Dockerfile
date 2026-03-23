# customized toolbox image can be used as debugging container process: kubectl debug -it <pod> --image=<quay.io> --target=<container> --share-processes
FROM fedora:40

RUN dnf install -y \
    bpftrace \
    kernel-devel \
    perf \
    strace \
    ltrace \
    tcpdump \
    htop \
    bcc-tools \
    procps-ng \
    psmisc \
    sysstat \
    lsof \
    pciutils \
    iproute \
    net-tools \
    curl \
    vim \
    passwd \
    util-linux \
    gdisk \
    hdparm \
    smartmontools \
    nvme-cli \
    blktrace \
    && dnf clean all

CMD ["/bin/bash"]
