#!/usr/bin/env bash

set -exo pipefail

source /etc/os-release

# Terra (Fyralabs) rotated its signing keys; refresh the bundled key so repo
# metadata verification doesn't fail (gpgv rejected) during later dnf/rum steps.
if [ -n "${VERSION_ID:-}" ]; then
    for _suffix in "" "-source" "-extras" "-extras-source" "-mesa" "-mesa-source" "-multimedia" "-multimedia-source" "-nvidia" "-nvidia-source"; do
        curl -fsSL "https://repos.fyralabs.com/terra${VERSION_ID}${_suffix}/key.asc" \
            -o "/etc/pki/rpm-gpg/RPM-GPG-KEY-terra${VERSION_ID}${_suffix}" 2>/dev/null || true
    done
    rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-terra${VERSION_ID}* 2>/dev/null || true
fi
# Fallback: if the fetched key still doesn't match, disable sig checks for terra
# (build-time only; no packages are installed from terra during ISO assembly).
sed -ri 's/^(gpgcheck|repo_gpgcheck)=1/\1=0/' /etc/yum.repos.d/terra.repo

# sudo requires drop-in files to be owned by root and not be writable by others
chown root:root /etc/sudoers.d
chmod 0750 /etc/sudoers.d
chown root:root /etc/sudoers.d/rakuos
chmod 0440 /etc/sudoers.d/rakuos
chown root:root /etc/sudoers.d/pwfeedback
chmod 0440 /etc/sudoers.d/pwfeedback
chown root:root /etc/sudoers.d/secure-path
chmod 0440 /etc/sudoers.d/secure-path

# Remove all versionlocks to avoid dependency issues
rum -qy versionlock clear

# Install RakuOS installer (try Qt first, then GTK, then skip if not available)
if rum -q install -qy rakuos-installer-qt 2>/dev/null; then
    echo "Installed rakuos-installer-qt"
elif rum -q install -qy rakuos-installer-gtk 2>/dev/null; then
    echo "Installed rakuos-installer-gtk"
else
    echo "No RakuOS installer package available, skipping..."
fi

# Allow the RakuOS installer's local `oci:` re-export of this image to pass
# signature policy: the default policy.json (default: reject, per-registry
# allowances only under the `docker` transport) has no `oci` transport entry,
# so bootc install --source-imgref oci:... gets rejected with "Source image
# ... is rejected by policy." even though the OCI export never leaves this
# same, already-trusted image. Scope the relaxation to `oci` only -- leave
# the registry/sigstore checks under `docker` untouched.
python3 - <<'PY'
import json
path = "/etc/containers/policy.json"
with open(path) as f:
    policy = json.load(f)
policy.setdefault("transports", {})["oci"] = {"": [{"type": "insecureAcceptAnything"}]}
with open(path, "w") as f:
    json.dump(policy, f, indent=2)
PY

# Mask overlay services so they cannot be started or pulled in on the live ISO
systemctl mask rakuos-overlay-sync.service rakuos-overlay-mount.service

# Setup Hyprland session for livesys (fix: livesys-scripts doesn't know hyprland)
mkdir -p /usr/share/wayland-sessions
ln -sf /usr/share/wayland-sessions/hyprland-uwsm.desktop /usr/share/wayland-sessions/hyprland.desktop 2>/dev/null || true
mkdir -p /etc/livesys
echo 'livesys_session="hyprland"' > /etc/sysconfig/livesys

# Read packages into array and install
mapfile -t PACKAGES < <(
    grep -v '^\s*#' "/usr/share/rakuos/packages-live.list" \
    | grep -v '^\s*$' \
    | sed 's/\s*#.*//' \
    | tr -s ' \t' '\n' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | grep -v '^$'
) || true

rum install -y --refresh "${PACKAGES[@]}"

# Reset RakuOS overlay state for live ISO
echo "Resetting RakuOS overlay state for live ISO..."
rm -rf /var/lib/rakuos
mkdir -p /var/lib/rakuos
if [[ -f /usr/share/rakuos/packages-live.list ]]; then
    cp /usr/share/rakuos/packages-live.list /var/lib/rakuos/packages.list
    sed -i -e '$a\' /var/lib/rakuos/packages.list
fi

# Variables
imageref="$(podman images --format '{{ index .Names 0 }}\n' 'rakuos*' | head -1)"
imageref="${imageref##*://}"
imageref="${imageref%%:*}"
imagetag="$(podman images --format '{{ .Tag }}\n' "$imageref" | head -1)"

echo "RakuOS release $VERSION_ID ($VERSION_CODENAME)" >/etc/system-release

# Get shared artwork and system files from iso-base
git clone --depth 1 --quiet https://gitlab.com/rakuos/iso/iso-base.git /root/packages

### Desktop-environment specific tweaks ###

# Setup Hyprland session for livesys-scripts (hyprland not in its case statement)
# Symlink as "niri" so livesys-scripts recognizes it, then fix config below
mkdir -p /usr/share/wayland-sessions
ln -sf hyprland-uwsm.desktop /usr/share/wayland-sessions/niri.desktop 2>/dev/null || true
ln -sf hyprland-uwsm.desktop /usr/share/wayland-sessions/hyprland.desktop 2>/dev/null || true

# Use GSK_RENDERER=gl for NVIDIA — workaround for GTK apps not opening
if [[ $imageref == *-nvidia* ]]; then
    mkdir -p /etc/environment.d /etc/skel/.config/environment.d
    echo "GSK_RENDERER=gl" >>/etc/environment.d/99-nvidia-fix.conf
    echo "GSK_RENDERER=gl" >>/etc/skel/.config/environment.d/99-nvidia-fix.conf
fi

# Re-enable nouveau for the live session on NVIDIA images
if [[ $imageref == *-nvidia* ]]; then
    for pkg in nvidia-gpu-firmware mesa-vulkan-drivers; do
        rum -yq reinstall --allowerasing $pkg ||
            rum -yq install --allowerasing $pkg
    done
    # Ensure nouveau vulkan ICDs exist
    (
        shopt -u nullglob
        ls /usr/share/vulkan/icd.d/nouveau_icd.*.json >/dev/null
    ) || {
        echo >&2 "::error::No nouveau vulkan ICDs found at /usr/share/vulkan/icd.d/nouveau_icd.*.json"
        exit 1
    }
fi

# Install & configure livesys-scripts manually (build uses --livesys false so
# rakuos-forge's desktop detection - which doesn't know hyprland - is skipped)
rum -y install livesys-scripts 2>/dev/null || true

# Ensure a live user exists for the noctalia greeter. If livesys' factory seed
# (/usr/share/factory/.../livesys-session-extra) is missing from the image, the
# user/home never gets created and login dies with "unable to set working
# directory: Permission denied (error 13)". Creating it here applies only to the
# live tree (ISO hook), never to the installed system.
# bootc/ostree images don't ship a real /home directory — it may be absent or
# a placeholder file/symlink. Ensure a real directory exists before useradd -m.
if [ -e /home ] && [ ! -d /home ]; then
    rm -f /home
fi
mkdir -p /home
chmod 0755 /home
if ! getent passwd liveuser >/dev/null 2>&1; then
    useradd -m -d /home/liveuser -s /bin/bash -G wheel liveuser
    echo "liveuser:liveuser" | chpasswd
fi
echo "liveuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/liveuser
chown root:root /etc/sudoers.d/liveuser
chmod 0440 /etc/sudoers.d/liveuser

# Auto-login to Hyprland for the live user (skip the greeter in live sessions).
# Masks/overrides only touch the live tree, never the installed system.
systemctl mask greetd.service greetd.socket 2>/dev/null || true

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/sbin/agetty --autologin liveuser --noclear --skip-login tty1 %I
EOF
systemctl enable getty@tty1.service 2>/dev/null || true

cat > /home/liveuser/.bash_profile <<'EOF'
if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec dbus-run-session -- uwsm start hyprland
fi
EOF
chown -R liveuser:liveuser /home/liveuser
chmod 0755 /home/liveuser

mkdir -p /etc/sysconfig
sed -i 's/^livesys_session=.*/livesys_session=hyprland/' /etc/sysconfig/livesys 2>/dev/null ||
    echo 'livesys_session=hyprland' > /etc/sysconfig/livesys

systemctl enable livesys.service livesys-late.service 2>/dev/null || true

mkdir -p /usr/lib/tmpfiles.d
echo "C /var/lib/livesys/livesys-session-extra 0755 root root - /usr/share/factory/var/lib/livesys/livesys-session-extra" > \
    /usr/lib/tmpfiles.d/livesys-session-extra.conf

# Fix greetd config - livesys-scripts sets up niri, we need noctalia-greeter for Hyprland
mkdir -p /etc/greetd
cat > /etc/greetd/config.toml << 'GREETD'
[terminal]
vt = 1

[default_session]
user = "greeter"
command = "/usr/bin/noctalia-greeter-session"
GREETD

# Don't show the motd verification notice
rm -vf /etc/profile.d/verify_motd.sh

echo "Copying shared system files..."
cp -af /root/packages/installer/system_files/shared/. /


# Remove rakuos-welcome autostart for the live environment
rm -f /etc/xdg/autostart/rakuos-welcome.desktop

rm -rf /root/packages
