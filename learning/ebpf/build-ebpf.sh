#!/bin/bash

# Only keep kernel version as the primary default
KERNEL_VERSION="5.14.0-427.40.1.el9_4.x86_64"
OUTPUT_FILE="Dockerfile"

# Function to extract UBI info from kernel version string
# Format is typically like: 5.14.0-427.42.1.el9_4.x86_64
# Where "el9_4" indicates RHEL/UBI 9.4
extract_ubi_info_from_kernel() {
    local kernel_version="$1"
    
    # Extract the "el9_4" part and then get "9" and "4" separately
    if [[ "$kernel_version" =~ el([0-9]+)_([0-9]+) ]]; then
        local major="${BASH_REMATCH[1]}"
        local minor="${BASH_REMATCH[2]}"
        echo "$major" "$major.$minor"
    else
        # Default values if extraction fails
        echo "9" "9.4"
    fi
}

# Function to display usage
function show_usage {
    echo "Usage: $0 [OPTIONS]"
    echo "Generate a Dockerfile with specified kernel version"
    echo ""
    echo "Options:"
    echo "  -k, --kernel-version VERSION   Specify kernel version (default: ${KERNEL_VERSION})"
    echo "                                 UBI version is auto-extracted from kernel version"
    echo "  -m, --ubi-major VERSION        Override UBI major version (auto-detected from kernel)"
    echo "  -u, --ubi-version VERSION      Override UBI version (auto-detected from kernel)"
    echo "  -b, --baseos-repo REPO         Override baseos repository (auto-generated from UBI major)"
    echo "  -a, --appstream-repo REPO      Override appstream repository (auto-generated from UBI major)"
    echo "  -o, --output FILE              Specify output file (default: ${OUTPUT_FILE})"
    echo "  -h, --help                     Display this help message"
    echo ""
    echo "Example:"
    echo "  $0 --kernel-version 5.14.0-427.42.1.el9_4.x86_64"
    echo ""
    echo "Note: The script automatically extracts UBI version information from the kernel version"
    echo "      by reading the 'el9_4' portion and deriving UBI major version (9) and full version (9.4)."
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -k|--kernel-version)
            KERNEL_VERSION="$2"
            shift 2
            ;;
        -u|--ubi-version)
            UBI_VERSION_OVERRIDE="$2"
            shift 2
            ;;
        -m|--ubi-major)
            UBI_MAJOR_OVERRIDE="$2"
            shift 2
            ;;
        -b|--baseos-repo)
            BASEOS_REPO_OVERRIDE="$2"
            shift 2
            ;;
        -a|--appstream-repo)
            APPSTREAM_REPO_OVERRIDE="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Extract UBI info from kernel version
read UBI_MAJOR_VERSION UBI_VERSION < <(extract_ubi_info_from_kernel "$KERNEL_VERSION")
echo "Auto-detected from kernel version: UBI${UBI_MAJOR_VERSION}:${UBI_VERSION}"

# Apply overrides if specified
if [[ -n "$UBI_MAJOR_OVERRIDE" ]]; then
    UBI_MAJOR_VERSION="$UBI_MAJOR_OVERRIDE"
    echo "Overriding UBI major version: $UBI_MAJOR_VERSION"
fi

if [[ -n "$UBI_VERSION_OVERRIDE" ]]; then
    UBI_VERSION="$UBI_VERSION_OVERRIDE"
    echo "Overriding UBI version: $UBI_VERSION"
fi

# Generate repo names based on UBI major version
BASEOS_REPO="rhel-${UBI_MAJOR_VERSION}-for-x86_64-baseos-eus-rpms"
APPSTREAM_REPO="rhel-${UBI_MAJOR_VERSION}-for-x86_64-appstream-eus-rpms"

# Apply repo overrides if specified
if [[ -n "$BASEOS_REPO_OVERRIDE" ]]; then
    BASEOS_REPO="$BASEOS_REPO_OVERRIDE"
    echo "Overriding baseos repo: $BASEOS_REPO"
fi

if [[ -n "$APPSTREAM_REPO_OVERRIDE" ]]; then
    APPSTREAM_REPO="$APPSTREAM_REPO_OVERRIDE"
    echo "Overriding appstream repo: $APPSTREAM_REPO"
fi

# Generate Dockerfile
cat > "$OUTPUT_FILE" << EOF
FROM registry.access.redhat.com/ubi${UBI_MAJOR_VERSION}:${UBI_VERSION}
RUN dnf install --disablerepo='*' --enablerepo=${BASEOS_REPO} --enablerepo=${APPSTREAM_REPO} --releasever=${UBI_VERSION} \\
        sysstat -y 
# Install OCP node version of kernel-core and kernel-headers      
RUN dnf install --disablerepo='*' --enablerepo=${BASEOS_REPO} --enablerepo=${APPSTREAM_REPO} --releasever=${UBI_VERSION} \\
        kernel-core-${KERNEL_VERSION} kernel-headers-${KERNEL_VERSION} -y
# Install bpftrace and bpftool, and their dependencies (bcc, python-bcc)
RUN dnf install --disablerepo='*' --enablerepo=${BASEOS_REPO} --enablerepo=${APPSTREAM_REPO} --releasever=${UBI_VERSION} \\
        bpftrace bpftool -y
RUN dnf clean all
EOF

echo "-----------------------------------"
echo "Dockerfile generated as ${OUTPUT_FILE} with:"
echo "  - UBI major version: ${UBI_MAJOR_VERSION}"
echo "  - UBI version: ${UBI_VERSION}" 
echo "  - Kernel version: ${KERNEL_VERSION}"
echo "  - Baseos repo: ${BASEOS_REPO}"
echo "  - Appstream repo: ${APPSTREAM_REPO}"

IMAGE_NAME="ebpf-$UBI_VERSION"
echo ""
echo "Building the image..."

podman build --volume /etc/pki/entitlement:/etc/pki/entitlement:ro,Z \
  --volume /etc/rhsm:/etc/rhsm:ro,Z \
  --volume /etc/yum.repos.d/redhat.repo:/etc/yum.repos.d/redhat.repo:ro,Z \
  -t ${IMAGE_NAME} -f ${OUTPUT_FILE} .

if [ $? -eq 0 ]; then
    echo "Build completed successfully! Image: ${IMAGE_NAME}"
else
    echo "Build failed. Please check for errors."
    exit 1
fi
