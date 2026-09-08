#!/usr/bin/env bash
set -exo pipefail

echo "Preparing initramfs for RakuOS Hyprland Live ISO"

# Swap kernel-p03-v3 for vanilla Fedora kernel for Secure Boot compatibility
# This is the same approach as niri-iso

# Remove all kernel-p03 variants
kernel_pkgs=(
    kernel-p03
    kernel-p03-core
    kernel-p03-devel
    kernel-p03-devel-matched
    kernel-p03-modules
    kernel-p03-modules-core
    kernel-p03-modules-extra
    kernel-p03-v2
    kernel-p03-v2-core
    kernel-p03-v2-devel
    kernel-p03-v2-devel-matched
    kernel-p03-v2-modules
    kernel-p03-v2-modules-core
    kernel-p03-v2-modules-extra
    kernel-p03-v3
    kernel-p03-v3-core
    kernel-p03-v3-devel
    kernel-p03-v3-devel-matched
    kernel-p03-v3-modules
    kernel-p03-v3-modules-core
    kernel-p03-v3-modules-extra
    kernel-p03-v4
    kernel-p03-v4-core
    kernel-p03-v4-devel
    kernel-p03-v4-devel-matched
    kernel-p03-v4-modules
    kernel-p03-v4-modules-core
    kernel-p03-v4-modules-extra
)
rum -y versionlock delete "${kernel_pkgs[@]}" 2>/dev/null || true
rum --setopt=protect_running_kernel=False -y remove "${kernel_pkgs[@]}" 2>/dev/null || true
(cd /usr/lib/modules && rm -rf -- ./*)

# Install vanilla Fedora kernel
rum -y --repo fedora,updates --setopt=tsflags=noscripts install kernel kernel-core kernel-devel kernel-modules

# Install firmware packages
rum -y install \
    amd-gpu-firmware \
    amd-ucode-firmware \
    intel-audio-firmware \
    intel-gpu-firmware \
    linux-firmware \
    nvidia-gpu-firmware \
    NetworkManager-wifi

# Get vanilla kernel version
KVER="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -1)"
echo "Using vanilla kernel: $KVER"

# Rebuild modules
akmods --force --kernels "$KVER" 2>/dev/null || true

# Create initramfs
kernel=$(find /usr/lib/modules -maxdepth 1 -type d -printf '%P\n' | grep .)
depmod "$kernel"

# Clean
rum clean all -yq

echo "Initramfs preparation complete"
