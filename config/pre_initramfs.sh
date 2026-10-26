#!/usr/bin/env bash
# pre_initramfs hook untuk ISO RakuOS Minimal (branch `minimal`).
#
# Ada dua hal yang dikerjakan di sini:
#
# 1. Live ISO WAJIB punya paket yang namanya `kernel`. rakuos-forge membangun
#    initramfs dengan query yang di-hardcode:
#
#        INSTALLED_KERNEL=$(rpm -q kernel --queryformat "%{evr}.%{arch}")
#        dracut --kver "$INSTALLED_KERNEL" ...
#
#    Image minimal hanya membawa kernel-rakuos-*, jadi query itu kosong
#    ("package kernel is not installed") dan dracut gagal. Solusinya sama
#    dengan ISO Hyprland: pasang kernel Fedora untuk live session.
#
#    Ini TIDAK mengubah kernel sistem hasil install. bootc menulis image
#    target (quay.io/rakuos/rakuos-minimal:staging) ke disk, jadi yang
#    terpasang tetap kernel-rakuos dari image tersebut; kernel Fedora hanya
#    dipakai selama live session/installer berjalan.
#
# 2. Firmware hardware + depmod untuk kernel yang benar-benar ada di rootfs.

set -exo pipefail

if command -v rum >/dev/null 2>&1; then
    pm() { rum -y "$@"; }
else
    pm() { dnf -y "$@"; }
fi

# --- 1. Kernel untuk live session -------------------------------------------
# Buang kernel RakuOS dari rootfs live: forge tidak bisa menemukannya lewat
# `rpm -q kernel`, dan dua kernel di /boot membuat pemilihan vmlinuz ambigu.
mapfile -t rakuos_kernels < <(rpm -qa 'kernel-rakuos*' 'kernel-p03*' 2>/dev/null || true)
if [ "${#rakuos_kernels[@]}" -gt 0 ]; then
    echo "Menghapus kernel RakuOS dari rootfs live: ${rakuos_kernels[*]}"
    rum -y versionlock delete "${rakuos_kernels[@]}" 2>/dev/null || true
    rpm -e --nodeps --noscripts "${rakuos_kernels[@]}"
fi

# Sisa module tree kernel lama dibersihkan supaya depmod tidak ambigu.
if [ -d /usr/lib/modules ]; then
    (cd /usr/lib/modules && rm -rf -- ./*)
fi

# --setopt=tsflags=noscripts: scriptlet kernel (depmod, initramfs, symlink
# /boot/vmlinuz) dilewati. Forge membangun initramfs sendiri dan mencari
# vmlinuz langsung, dan depmod kita jalankan manual di bawah.
pm --repo fedora,updates --setopt=tsflags=noscripts \
    --exclude='kernel-rakuos*' --exclude='kernel-p03*' \
    install kernel kernel-core kernel-modules

# --- 2. Firmware untuk live boot -------------------------------------------
# Tanpa ini live ISO bisa kehilangan wifi/GPU/audio di laptop tertentu.
pm install \
    linux-firmware \
    amd-gpu-firmware \
    amd-ucode-firmware \
    intel-audio-firmware \
    intel-gpu-firmware \
    nvidia-gpu-firmware \
    NetworkManager-wifi || true

# --- 3. depmod --------------------------------------------------------------
# JANGAN `depmod -a` tanpa argumen. Hook ini berjalan di container yang
# memakai kernel HOST (podman --rootfs), jadi `uname -r` mengembalikan kernel
# Ryoku di mesin build, bukan kernel yang ada di rootfs. Petakan setiap module
# tree yang benar-benar ada.
modules_found=0
for dir in /lib/modules/*/; do
    [ -d "$dir" ] || continue
    kver="$(basename "$dir")"
    echo "depmod untuk kernel rootfs: $kver"
    depmod -a "$kver"
    modules_found=1
done
if [ "$modules_found" -eq 0 ]; then
    echo "Tidak ada /lib/modules/* di rootfs; depmod dilewati (dracut menanganinya)."
fi

# Bukti untuk log build: forge akan memakai kernel pertama dari query ini.
echo "Kernel yang akan dipakai forge: $(rpm -q kernel --queryformat '%{evr}.%{arch}\n' | tail -n 1)"

# Buang cache paket supaya tidak ikut masuk ke squashfs live.
if command -v rum >/dev/null 2>&1; then
    rum clean all -yq || true
else
    dnf clean all -yq || true
fi

echo "Initramfs preparation complete (minimal)"
