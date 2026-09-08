# RakuOS Hyprland ISO

Local build scripts for the RakuOS Hyprland live ISO, built from
`quay.io/mindset404/hyprland-atomic`.

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

# Build ISO (image: quay.io/mindset404/hyprland-atomic:latest)
sudo ./build-local.sh

# Or a specific date tag (e.g. kept under the retention policy)
sudo ./build-local.sh 20260908
```

## Output

- ISO: `output/rakuos-hyprland-latest-amd64.iso`
- SHA256: `output/rakuos-hyprland-latest-amd64.iso.sha256`

## What the build does

- Pulls `quay.io/mindset404/hyprland-atomic:latest` (built in the
  `tofan79/hyprland-rakuos` repo CI)
- Builds a live ISO with `rakuos-forge build --livesys false` — livesys
  handling is done manually in `config/configure-iso.sh` (greetd/noctalia
  greeter, hyprland session), since livesys-scripts runs before the config
  hooks.
- `config/pre_initramfs.sh` sets up the kernel/initramfs based on the
  NVIDIA dGPU stack.

## Image Source

Image: `quay.io/mindset404/hyprland-atomic`