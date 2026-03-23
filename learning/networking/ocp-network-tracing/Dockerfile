FROM fedora:latest

# Install networking and troubleshooting tools
RUN dnf install -y \
    # Network analysis tools
    tcpdump \
    wireshark-cli \
    # Connection tracking
    conntrack-tools \
    # IP and routing tools
    iproute \
    iputils \
    # DNS tools
    bind-utils \
    # Network testing
    curl \
    wget \
    nmap-ncat \
    # Performance testing
    iperf3 \
    # Network scanning
    nmap \
    # Traffic control and bridges
    bridge-utils \
    ethtool \
    # Process and system tools
    procps-ng \
    net-tools \
    lsof \
    strace \
    # Additional monitoring
    iftop \
    iotop \
    htop \
    mtr \
    # Utilities
    bash-completion \
    vim \
    less \
    # Additional network tools
    socat \
    traceroute \
    telnet \
    nc \
    && dnf clean all

# Set bash as default shell
CMD ["/bin/bash"]
