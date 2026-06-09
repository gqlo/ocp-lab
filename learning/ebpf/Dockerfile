# Toolbox image for: kubectl -n openshift-dns debug -it <dns-default-pod> --image=quay.io/rh_ee_lguoqing/toolbox --target=dns --share-processes --profile=netadmin
FROM fedora:40

RUN dnf install -y \
    # eBPF / tracing
    bpftrace \
    bcc-tools \
    kernel-devel \
    perf \
    strace \
    ltrace \
    blktrace \
    # Network capture & analysis
    tcpdump \
    wireshark-cli \
    conntrack-tools \
    # IP / DNS / routing
    iproute \
    iputils \
    bind-utils \
    net-tools \
    bridge-utils \
    ethtool \
    # Network testing
    curl \
    wget \
    nmap-ncat \
    nmap \
    iperf3 \
    socat \
    traceroute \
    telnet \
    nc \
    mtr \
    # Process / system
    procps-ng \
    psmisc \
    sysstat \
    lsof \
    pciutils \
    iftop \
    iotop \
    htop \
    # Storage / disk
    gdisk \
    hdparm \
    smartmontools \
    nvme-cli \
    # Shell / utilities
    util-linux \
    passwd \
    bash-completion \
    vim \
    less \
    && dnf clean all

CMD ["/bin/bash"]
