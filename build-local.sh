#!/usr/bin/env bash
# Build the RakuOS Minimal ISO locally using the rakuos-forge binary.
#
# Branch `minimal`: image sumbernya quay.io/rakuos/rakuos-minimal, dan live
# session-nya TTY + rakuos-installer-cli (text mode, archinstall-style). Tidak
# ada compositor dan tidak ada greeter -- beda dengan branch `main` yang
# membangun ISO Hyprland lengkap dengan greetd/Noctalia.
#
# Usage: ./build-local.sh [branch_slug]
#   branch_slug defaults to "staging"
#   (i.e. quay.io/rakuos/rakuos-minimal:staging)
#
# The image repository can be overridden with the IMAGE_REPO environment
# variable, e.g. IMAGE_REPO=quay.io/mindset404/rakuos-minimal
#
# Requires `rakuos-forge` to be installed (dnf install rakuos-forge, after
# adding https://repo.rakuos.org/rakuos.repo).

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Re-executing with sudo (build needs real root for privileged container setup)..."
  exec sudo --preserve-env=COMPRESSION,BUILDER_DISTRO,PLATFORM,IMAGE_REPO "$0" "$@"
fi

if ! command -v rakuos-forge >/dev/null 2>&1; then
  echo "ERROR: rakuos-forge is not installed (dnf install rakuos-forge, after adding https://repo.rakuos.org/rakuos.repo)" >&2
  exit 1
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Clean up leftovers from previous runs (stale output.iso/output/, work/) so a
# failed/older run can never be mistaken for the result of this one.
rm -f "${SELF_DIR}/output.iso"
rm -rf "${SELF_DIR}/output"
rm -rf "${SELF_DIR}/work"

IMAGE_REPO="${IMAGE_REPO:-quay.io/rakuos/rakuos-minimal}"
BRANCH_SLUG="${1:-staging}"
IMAGE_REF="${IMAGE_REPO}:${BRANCH_SLUG}"
COMPRESSION="${COMPRESSION:-squashfs}"
PLATFORM="${PLATFORM:-amd64}"

if [ "${BRANCH_SLUG}" = "latest" ]; then
  ISO_NAME="rakuos-minimal-latest-${PLATFORM}.iso"
else
  ISO_NAME="rakuos-minimal-${BRANCH_SLUG}-latest-${PLATFORM}.iso"
fi

export RAKUFORGE_BUILDER_DISTRO="${BUILDER_DISTRO:-fedora}"
export HOOK_post_rootfs="${SELF_DIR}/config/configure-iso.sh"
export HOOK_pre_initramfs="${SELF_DIR}/config/pre_initramfs.sh"

cd "${SELF_DIR}"

# Force a fresh pull of the target image so a stale local ":latest" cache can
# never produce an ISO from an older build.
podman pull "${IMAGE_REF}"

# --livesys false: livesys-scripts tidak dipakai di ISO minimal (tidak ada
# session desktop yang perlu dibuatkan). Semua yang dibutuhkan live TTY
# dipasang sendiri oleh config/configure-iso.sh.
rakuos-forge build "${IMAGE_REF}" --compression "${COMPRESSION}" --container-image "${IMAGE_REF}" --livesys false

mkdir -p "${SELF_DIR}/output"
mv "${SELF_DIR}/output.iso" "${SELF_DIR}/output/${ISO_NAME}"

( cd "${SELF_DIR}/output" && sha256sum "${ISO_NAME}" > "${ISO_NAME}.sha256" )

echo "Built: ${SELF_DIR}/output/${ISO_NAME}"
echo "SHA256: ${SELF_DIR}/output/${ISO_NAME}.sha256"
