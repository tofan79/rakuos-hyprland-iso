#!/usr/bin/env bash
# Diambil dari repo resmi rakuos-minimal-iso (gitlab.com/rakuos/iso/rakuos-minimal-iso).
# Logikanya dipakai apa adanya: forge membangun initramfs dengan query hardcoded
# `rpm -q kernel`, jadi live ISO wajib punya paket kernel Fedora; kernel RakuOS
# (dan rakuos-kmod-* yang dibangun untuknya) harus benar-benar hilang dulu.
# Sistem hasil install tetap memakai kernel-rakuos dari image target.
set -exo pipefail

echo "Preparing initramfs for RakuOS Linux Live ISO"

# Swap the RakuOS kernel for a vanilla signed Fedora kernel so the live ISO
# boots with Secure Boot enabled. The installed system gets kernel-rakuos
# from the container image — this only affects the live boot environment.
# Every RakuOS kernel package the image can carry: both flavors (kernel-rakuos
# and the Steam Deck kernel-rakuos-deck), each x86-64 level, stable and
# staging, with all their subpackages.
kernel_pkgs=()
for flavor in rakuos rakuos-deck; do
    for isa in v2 v3 v4; do
        for channel in "" -staging; do
            for sub in "" -core -devel -devel-matched -modules -modules-core -modules-extra; do
                kernel_pkgs+=("kernel-${flavor}-${isa}${channel}${sub}")
            done
        done
    done
done
# Only the ones actually installed: given names that aren't installed, the
# removal refuses everything, which used to leave the RakuOS kernel (and its
# -devel, so akmod-wl's posttrans built wl for it too) in the live image.
# rpm directly, without scriptlets or dependency checks: rum protects
# kernels, and the kernel's removal scriptlets don't apply in an image
# build. No "|| true": a RakuOS kernel left behind must stop the build.
mapfile -t installed_kernel_pkgs < <(rpm -q --qf '%{NAME}\n' "${kernel_pkgs[@]}" | grep -v ' is not installed$' || true)
if [ "${#installed_kernel_pkgs[@]}" -gt 0 ]; then
    rum -y versionlock delete "${installed_kernel_pkgs[@]}" 2>/dev/null || true
    rpm -e --nodeps --noscripts "${installed_kernel_pkgs[@]}"
fi
leftover="$(rpm -qa 'kernel-rakuos*')"
if [ -n "$leftover" ]; then
    echo "ERROR: RakuOS kernel packages still installed:"; echo "$leftover"; exit 1
fi
# The image's RakuOS-signed drivers (rakuos-kmod-*) are built for the RakuOS
# kernels removed above, and rakuos-kmod-wl conflicts with the akmod-wl
# installed below for the Fedora kernel. --nodeps keeps their companion
# packages (broadcom-wl, ...), whose <name>-kmod the akmods take over.
mapfile -t rakuos_kmods < <(rpm -qa --qf '%{NAME}\n' 'rakuos-kmod-*')
if [ "${#rakuos_kmods[@]}" -gt 0 ]; then
    rpm -e --nodeps "${rakuos_kmods[@]}"
fi
(cd /usr/lib/modules && rm -rf -- ./*)
# --exclude: nothing may pull a RakuOS or deck kernel back into the live image.
rum -y --repo fedora,updates --setopt=tsflags=noscripts --exclude='kernel-rakuos*' install kernel kernel-core kernel-devel kernel-modules

# akmods and akmod-wl build Broadcom Wi-Fi for the live session's Fedora
# kernel (akmods --force below). Images no longer ship akmods, and RPM
# Fusion, where akmod-wl and broadcom-wl come from, is off by default, so
# its package repos are enabled for this one command.
rum -y --exclude='kernel-rakuos*' \
    --enablerepo=rpmfusion-free,rpmfusion-free-updates,rpmfusion-nonfree,rpmfusion-nonfree-updates \
    install \
    akmods \
    akmod-wl \
    virtualbox-guest-additions \
    amd-gpu-firmware \
    amd-ucode-firmware \
    cirrus-audio-firmware \
    intel-audio-firmware \
    intel-gpu-firmware \
    linux-firmware \
    nvidia-gpu-firmware \
    qcom-wwan-firmware \
    atheros-firmware \
    b43-fwcutter \
    b43-openfwwf \
    brcmfmac-firmware \
    iwlegacy-firmware \
    iwlwifi-dvm-firmware \
    iwlwifi-mvm-firmware \
    libertas-firmware \
    mt7xxx-firmware \
    nxpwireless-firmware \
    realtek-firmware \
    tiwilink-firmware \
    atmel-firmware \
    zd1211-firmware \
    broadcom-wl \
    NetworkManager-wifi

KVER="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -1)"
akmods --force --kernels "$KVER"

# Only the Fedora kernel belongs in the live image; drop any other modules
# tree (one appearing here means something built for a kernel that should be
# gone).
find /usr/lib/modules -mindepth 1 -maxdepth 1 ! -name "$KVER" -print -exec rm -rf {} +
depmod "$KVER"
rum clean all -yq
