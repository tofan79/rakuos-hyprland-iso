#!/usr/bin/env bash
set -exo pipefail

echo "Preparing initramfs for RakuOS Hyprland Live ISO"

# Replace RakuOS/P03 kernels with a signed Fedora kernel for Secure Boot.
# Include the older P03 names and current RakuOS flavors (including Steam
# Deck) because the base image has used each naming scheme over time.
kernel_pkgs=(
    kernel-p03
    kernel-p03-core
    kernel-p03-devel
    kernel-p03-devel-matched
    kernel-p03-modules
    kernel-p03-modules-core
    kernel-p03-modules-extra
)
for flavor in p03 rakuos rakuos-deck; do
    for isa in v2 v3 v4; do
        for channel in "" -staging; do
            for sub in "" -core -devel -devel-matched -modules -modules-core -modules-extra; do
                kernel_pkgs+=("kernel-${flavor}-${isa}${channel}${sub}")
            done
        done
    done
done

# Query only installed packages: asking rum to remove a mixed list of present
# and absent names can make it refuse the entire removal. rpm bypasses rum's
# running-kernel protection during this image build.
mapfile -t installed_kernel_pkgs < <(
    rpm -q --qf '%{NAME}\n' "${kernel_pkgs[@]}" 2>/dev/null || true
)
if [ "${#installed_kernel_pkgs[@]}" -gt 0 ]; then
    rum -y versionlock delete "${installed_kernel_pkgs[@]}" 2>/dev/null || true
    rpm -e --nodeps --noscripts "${installed_kernel_pkgs[@]}"
fi

leftover="$(rpm -qa 'kernel-rakuos*' 'kernel-p03*')"
if [ -n "$leftover" ]; then
    echo "ERROR: RakuOS/P03 kernel packages still installed:"
    echo "$leftover"
    exit 1
fi

# Remove module trees from the image before installing the Fedora kernel.
(cd /usr/lib/modules && rm -rf -- ./*)

rum -y --repo fedora,updates --setopt=tsflags=noscripts \
    --exclude='kernel-rakuos*' --exclude='kernel-p03*' \
    install kernel kernel-core kernel-devel kernel-modules

# Install firmware packages needed by common live hardware.
rum -y install \
    amd-gpu-firmware \
    amd-ucode-firmware \
    intel-audio-firmware \
    intel-gpu-firmware \
    linux-firmware \
    nvidia-gpu-firmware \
    NetworkManager-wifi

KVER="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -1)"
echo "Using vanilla kernel: $KVER"

# Fail the ISO build if out-of-tree modules cannot be rebuilt for this kernel.
akmods --force --kernels "$KVER"

# Keep only the Fedora kernel module tree and generate its dependency map.
find /usr/lib/modules -mindepth 1 -maxdepth 1 ! -name "$KVER" -print -exec rm -rf {} +
depmod "$KVER"

rum clean all -yq
echo "Initramfs preparation complete"
