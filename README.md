# RakuOS Hyprland ISO

Local build scripts for the RakuOS Hyprland live ISO, built from
`quay.io/rakuos/rakuos-hyprland-nvidia-v3`.

## Requirements

```bash
# 1. Add the RakuOS repo and install rakuos-forge
sudo dnf install -y https://repo.rakuos.org/rakuos.repo
sudo dnf install -y rakuos-forge

# 2. Needs network access to quay.io (image pull) and a container runtime
#    (podman) available to build the live system.
```

## Build

```bash
cd rakuos-hyprland-iso

# Build ISO (image: quay.io/rakuos/rakuos-hyprland-nvidia-v3:staging)
sudo ./build-local.sh

# Or a specific tag
sudo ./build-local.sh staging.20261001

# Or point at a different image repository
sudo IMAGE_REPO=quay.io/mindset404/hyprland-nvidia-v3 ./build-local.sh latest
```

## Output

- ISO: `output/rakuos-hyprland-staging-latest-amd64.iso`
- SHA256: `output/rakuos-hyprland-staging-latest-amd64.iso.sha256`

(The `staging-latest` part comes from the branch slug being inserted into the
name when it is not `latest`.)

## What the build does

- Pulls `quay.io/rakuos/rakuos-hyprland-nvidia-v3:staging` by default
- Builds a live ISO with `rakuos-forge build --livesys false` — livesys
  handling is done manually in `config/configure-iso.sh` (greetd +
  Noctalia Greeter, `liveuser` autologin, and the Hyprland Wayland/UWSM
  session), since livesys-scripts runs before the config hooks.
- `config/pre_initramfs.sh` sets up the kernel/initramfs based on the
  NVIDIA dGPU stack.

## Live greeter and autologin

The live session uses **greetd with the Noctalia Greeter** — the same greeter
as the installed image — and autologins into Hyprland for `liveuser` via
greetd's `[initial_session]`. Log out at the live desktop and the greeter
appears, so it is still a login screen, just not one you have to click through
on first boot.

`liveuser` is created by `livesys.service` at boot, not at build time:
build-time `/home` is lost in the squashfs. `greetd.service` is ordered after
`livesys.service` so the autologin does not race the user creation.

The autologin command is `/usr/local/bin/live-session-launcher`, which starts
the UWSM-managed session when a systemd `--user` bus is available and falls back
to running Hyprland directly when it is not. Fallback exists because `uwsm`
waits forever for `org.freedesktop.systemd1` if greetd's PAM stack lost
`pam_systemd.so`; the script re-asserts that line after copying iso-base's
shared files.

## Noctalia polkit agent (live session)

Noctalia's built-in polkit agent (needed by `rakuos-installer-qt` and other
privileged GUI apps) ships **off by default**. On the live ISO, enable it once
per session: **Noctalia settings → polkit agent → on** — otherwise the
installer fails with:

```
[err] Error creating textual authentication agent: Error opening current
controlling terminal for the process ('/dev/tty'): No such device or address
```

## Image Source

Default image: `quay.io/rakuos/rakuos-hyprland-nvidia-v3:staging`

Override with `IMAGE_REPO` and the first argument. Note that switching to the
official repository means the customisations from `tofan79/custome-rakuos`
(the Bibata cursor for the login screen, the `pam_gnome_keyring` gate, the
opt-in `wl` blacklist and the skel device pins) are **not** present, because
they only ever existed in that image.