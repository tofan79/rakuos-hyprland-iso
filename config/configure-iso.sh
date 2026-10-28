#!/usr/bin/env bash
# post_rootfs hook untuk ISO RakuOS Minimal (branch `minimal`).
#
# ISO ini TIDAK menjalankan compositor atau greeter. Live session-nya TTY
# biasa: getty di tty1 autologin sebagai root, lalu rakuos-installer-cli
# (text mode, archinstall-style) langsung jalan. Setelah instalasi selesai,
# yang ditulis ke disk adalah image sumber ISO ini --
# /usr/share/rakuos/source-imgref, dibakar oleh rakuos-forge.
#
# Bedanya dengan branch `main` (ISO Hyprland) sengaja dijaga sekecil mungkin:
# bagian policy OCI, masking overlay, dan pembersihan motd sama; bagian
# greetd/Hyprland/livesys diganti dengan TTY + installer teks.

set -exo pipefail

source /etc/os-release

# dnf/rum harus tahan mirrorlist yang sesekali tidak memberi mirror.
grep -qx 'retries=10' /etc/dnf/dnf.conf 2>/dev/null || echo 'retries=10' >> /etc/dnf/dnf.conf
grep -qx 'timeout=60' /etc/dnf/dnf.conf 2>/dev/null || echo 'timeout=60' >> /etc/dnf/dnf.conf

# `bootc install` mengekspor image sumber lewat transport `oci:` lalu membacanya
# lagi dari direktori lokal. policy.json bawaan tidak punya entri untuk
# transport `oci`, jadi tanpa ini instalasi gagal dengan
# "Source image ... is rejected by policy." Longgarkan hanya `oci`; pemeriksaan
# registry/sigstore di transport `docker` tidak disentuh.
python3 - <<'PY'
import json
path = "/etc/containers/policy.json"
with open(path) as f:
    policy = json.load(f)
policy.setdefault("transports", {})["oci"] = {"": [{"type": "insecureAcceptAnything"}]}
with open(path, "w") as f:
    json.dump(policy, f, indent=2)
PY

# Overlay RakuOS tidak dipakai di live ISO (sama seperti ISO desktop).
systemctl mask rakuos-overlay-sync.service rakuos-overlay-mount.service

# rum adalah pembungkus dnf milik RakuOS; pakai dnf kalau image tidak punya rum.
if command -v rum >/dev/null 2>&1; then
    pm_install() { rum -y install "$@"; }
else
    pm_install() { dnf -y install "$@"; }
fi

# Paket yang dipakai rakuos-installer-cli saat menulis disk. Image minimal
# tidak menjamin semuanya ada; kebanyakan sudah ikut, sisanya dipasang di sini.
#   dosfstools  -> mkfs.fat (partisi EFI)
#   e2fsprogs   -> mkfs.ext4 (root/boot)
#   xfsprogs    -> mkfs.xfs
#   btrfs-progs -> mkfs.btrfs
#   parted      -> partprobe
#   lvm2        -> pvs
#   cryptsetup  -> LUKS
#   rsync, tar  -> penyalinan data instalasi
#   os-prober   -> deteksi OS lain (dual boot)
#   mokutil     -> pendaftaran key Secure Boot
pm_install \
    rakuos-installer-cli \
    dosfstools \
    e2fsprogs \
    xfsprogs \
    btrfs-progs \
    parted \
    lvm2 \
    cryptsetup \
    rsync \
    tar \
    os-prober \
    mokutil

# Pastikan installer bisa menulis ke disk tanpa polkit/GUI.
install -d /etc/xdg

# --- Live session: TTY + installer -----------------------------------------
#
# root autologin di tty1. Akun liveuser tidak dibuat: installer berjalan
# sebagai root, dan akun target dibuat sendiri oleh installer.
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'UNIT'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- \\u' --noclear --autologin root %I $TERM
Type=idle
UNIT

# Jangan jalankan installer di tty lain / shell non-interaktif.
cat > /root/.bash_profile << 'PROFILE'
# Live ISO minimal: tty1 langsung masuk installer, tty lain shell biasa.
if [ "$(tty)" = "/dev/tty1" ] && [ ! -e /run/rakuos-live-installer.started ]; then
    touch /run/rakuos-live-installer.started
    /usr/local/bin/rakuos-live-installer
fi
PROFILE

# Tunggu jaringan sebentar supaya installer tidak langsung gagal saat
# mengambil metadata repo, lalu jalankan installer. Kalau installer keluar
# (selesai/gagal), shell root tetap tersedia untuk memeriksa log.
cat > /usr/local/bin/rakuos-live-installer << 'LAUNCHER'
#!/usr/bin/env bash
# NetworkManager-wait-online bisa menggantung di VM tanpa NIC; batasi 20 detik.
timeout 20 systemctl start NetworkManager-wait-online.service 2>/dev/null || true
exec /usr/bin/rakuos-installer-cli
LAUNCHER
chmod 0755 /usr/local/bin/rakuos-live-installer

# Boot ke TTY, bukan graphical.target: tidak ada greeter/desktop di ISO ini.
systemctl set-default multi-user.target
systemctl enable getty@tty1.service

# Image membawa kmscon. kmsconvt@.service punya
#   Conflicts=getty@%i.service
#   Alias=autovt@.service
#   Before=getty.target
# jadi di tty1 kmscon selalu menang atas getty@tty1, dan autologin root kita
# tidak pernah dipakai: yang muncul adalah prompt login kmscon (tanpa
# kredensial yang berguna, karena root di image ini terkunci). Matikan kmscon
# dan arahkan autovt@ (VT yang dibuat on-demand) kembali ke getty.
systemctl mask kmsconvt@.service
rm -f /etc/systemd/system/getty.target.wants/kmsconvt@tty*.service
ln -sf /usr/lib/systemd/system/getty@.service /etc/systemd/system/autovt@.service

# tty2-tty6 tetap getty biasa untuk melihat log saat installer bermasalah.
for t in 2 3 4 5 6; do
    systemctl enable "getty@tty$t.service" 2>/dev/null || true
done

# Live session memang tanpa password (tty1 sudah autologin root). Kalau
# autologin gagal, login manual di tty lain cukup tekan Enter.
passwd -d root || true

# Kalau image/iso-base membawa display manager, pastikan tidak menyerobot tty1.
for dm in greetd.service gdm.service sddm.service lightdm.service; do
    systemctl disable "$dm" 2>/dev/null || true
    systemctl mask "$dm" 2>/dev/null || true
done
rm -rf /etc/sddm.conf.d /etc/systemd/system/greetd.service.d /etc/systemd/system/sddm.service.d

# Jangan tampilkan notice verifikasi motd di live ISO.
rm -vf /etc/profile.d/verify_motd.sh
