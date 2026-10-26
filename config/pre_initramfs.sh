#!/usr/bin/env bash
# pre_initramfs hook untuk ISO RakuOS Minimal (branch `minimal`).
#
# ISO Hyprland (branch `main`) mengganti kernel RakuOS dengan kernel Fedora
# signed supaya bisa boot dengan Secure Boot. ISO minimal TIDAK melakukannya:
# kernel yang dipakai live session adalah kernel image itu sendiri
# (kernel-rakuos-*), jadi kernel yang diinstal ke disk sama persis dengan yang
# dipakai saat instalasi.
#
# Tugas hook ini tinggal dua: pastikan firmware perangkat keras tersedia untuk
# live boot di mesin nyata (wifi, GPU, audio), dan rapikan modul + cache paket
# sebelum forge/dracut membangun initramfs.

set -exo pipefail

if command -v rum >/dev/null 2>&1; then
    pm_install() { rum -y install "$@"; }
else
    pm_install() { dnf -y install "$@"; }
fi

# Firmware ini tidak selalu ikut di image minimal, tetapi tanpa salah satunya
# live ISO bisa kehilangan wifi/GPU/audio di laptop tertentu.
pm_install \
    linux-firmware \
    amd-gpu-firmware \
    amd-ucode-firmware \
    intel-audio-firmware \
    intel-gpu-firmware \
    nvidia-gpu-firmware \
    NetworkManager-wifi || true

# Peta dependensi modul harus ada sebelum initramfs dibangun.
#
# JANGAN pakai `depmod -a` tanpa argumen. Hook ini berjalan di container yang
# memakai kernel HOST (lewat --rootfs), jadi `uname -r` mengembalikan kernel
# Ryoku di mesin build (mis. 7.3.0-rakuos.2.v3.staging.fc45), bukan kernel yang
# ada di rootfs image (mis. 7.3.0-rakuos.3.v2.staging.fc45). Gejalanya:
#   depmod: ERROR: could not open directory /lib/modules/7.3.0-rakuos.2.v3...
# Petakan setiap module tree yang benar-benar ada di rootfs.
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

# Buang cache paket supaya tidak ikut masuk ke squashfs live.
if command -v rum >/dev/null 2>&1; then
    rum clean all -yq || true
else
    dnf clean all -yq || true
fi

echo "Initramfs preparation complete (minimal)"
