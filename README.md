# RakuOS Minimal ISO (branch `minimal`)

Live ISO minimal dari image bootc `quay.io/rakuos/rakuos-minimal:staging`,
dengan **rakuos-installer-cli** (text mode, archinstall-style) sebagai
installer-nya. Tidak ada compositor, greeter, atau desktop di live session.

Branch `main` tetap ISO Hyprland lengkap (greetd + Noctalia Greeter). Branch
ini hanya mengganti bagian live session-nya.

## Requirements

```bash
# 1. Tambahkan repo RakuOS lalu pasang rakuos-forge
sudo dnf install -y https://repo.rakuos.org/rakuos.repo
sudo dnf install -y rakuos-forge

# 2. Butuh podman + akses jaringan (pull image, ambil paket repo)
```

## Build

```bash
# ISO dari quay.io/rakuos/rakuos-minimal:staging
sudo ./build-local.sh

# Tag lain
sudo ./build-local.sh staging.20261026

# Image lain (mis. image hasil build sendiri)
sudo IMAGE_REPO=quay.io/mindset404/rakuos-minimal ./build-local.sh staging
```

Output:

- `output/rakuos-minimal-staging-latest-amd64.iso`
- `output/rakuos-minimal-staging-latest-amd64.iso.sha256`

## Isi live session

| Bagian | Perilaku |
|---|---|
| Target boot | `multi-user.target` (TTY) |
| tty1 | autologin `root` → `/usr/local/bin/rakuos-live-installer` |
| Installer | `/usr/bin/rakuos-installer-cli` |
| Image tujuan | dibaca dari `/usr/share/rakuos/source-imgref` (ditulis forge) |
| Jaringan | `NetworkManager-wait-online` ditunggu maksimal 20 detik |

Kalau installer keluar (selesai atau gagal), sesi tty1 kembali ke shell root
supaya log bisa diperiksa. `journalctl -u getty@tty1` dan
`/var/log/rakuos-install*` adalah tempat pertama untuk melihat kegagalan.

## Yang dilakukan hook

`config/configure-iso.sh` (post_rootfs):

- melonggarkan `policy.json` hanya untuk transport `oci` (syarat
  `bootc install --source-imgref oci:...`)
- memasang `rakuos-installer-cli` + tool disk yang dibutuhkan backend
  (`mkfs.*`, `partprobe`, `cryptsetup`, `rsync`, `os-prober`, `mokutil`)
- mengatur autologin root di tty1 dan autostart installer
- mematikan/memask semua display manager, `set-default multi-user.target`

`config/pre_initramfs.sh`:

- **tidak** mengganti kernel (beda dengan ISO Hyprland yang memakai kernel
  Fedora signed untuk Secure Boot)
- memasang firmware hardware untuk live boot lalu `depmod -a`

## Catatan

- `rakuos-minimal` belum tentu membawa `/usr/share/rakuos/packages-live.list`.
  Hook sengaja tidak bergantung padanya; paket live dipasang eksplisit.
- Instalasi memakai image yang sama dengan live session, jadi hasil install =
  image minimal (CLI), bukan Hyprland.
