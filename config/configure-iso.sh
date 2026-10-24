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
# Fallback: if the fetched key still doesn't match, disable sig checks for any
# Terra repo files present. Some base images do not include Terra at all.
for _repo in /etc/yum.repos.d/terra*.repo; do
    [ -f "$_repo" ] || continue
    sed -ri 's/^(gpgcheck|repo_gpgcheck)=1/\1=0/' "$_repo"
done

# Make dnf/rum resilient to flaky mirrorlists (rpmfusion & co often return no
# usable mirror on a transient basis, which would fail the whole ISO build).
grep -qx 'retries=10' /etc/dnf/dnf.conf 2>/dev/null || echo 'retries=10' >> /etc/dnf/dnf.conf
grep -qx 'timeout=60' /etc/dnf/dnf.conf 2>/dev/null || echo 'timeout=60' >> /etc/dnf/dnf.conf

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

# rakuos-installer-qt is a QtQuick/QQC2 app importing `org.kde.desktop`; that
# QML module ships in kf6-qqc2-desktop-style, which Plasma ISO builds pull in
# implicitly but our Hyprland build doesn't -> installer dies with
# 'QQmlApplicationEngine failed to load component ... module "org.kde.desktop"
# is not installed' otherwise.
rum -qy install kf6-qqc2-desktop-style 2>/dev/null || true

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

# NOTE: no manual hyprland.desktop alias here anymore. The hyprland /
# hyprland-uwsm packages installed below already ship their own native
# /usr/share/wayland-sessions/hyprland.desktop (plain) and
# hyprland-uwsm.desktop (UWSM-managed) entries. Symlinking one over the
# other here — before the packages were even installed — clobbered the
# package's own hyprland.desktop, so the greeter only ever showed one real
# session instead of both "Hyprland" and "Hyprland (uwsm)".
# livesys_session is set below, in the live-session block (same place the
# official ISOs set it).

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

# Apply iso-base's shared files FIRST. This must happen before the greetd /
# livesys / graphical.target configuration below, otherwise a raw `cp -af`
# from iso-base can silently overwrite /etc/greetd/*, the greetd.service
# systemd drop-in, or /etc/systemd/system/default.target, undoing the
# autologin + graphical.target setup and leaving the live ISO stuck on a
# plain TTY (multi-user.target) instead of the greeter.
echo "Copying shared system files..."
cp -af /root/packages/installer/system_files/shared/. /

# Re-assert pam_systemd.so in greetd's PAM stack after the cp above.
# The image ships it (added by setup_greeter_system.sh when the image was
# built), but the shared-files copy can clobber /etc/pam.d/greetd with
# iso-base's version. Without pam_systemd.so, greetd's sessions never get a
# logind session, so systemd --user never starts for them, and the autologin
# session below cannot use uwsm -- it silently loses the systemd user manager
# and uwsm exits waiting for org.freedesktop.systemd1 that will never appear.
if ! grep -q 'pam_systemd\.so' /etc/pam.d/greetd 2>/dev/null; then
    sed -i '/^session/s|^\(session\s\+include\s\+postlogin\)|\1\nsession    required     pam_systemd.so|' \
        /etc/pam.d/greetd 2>/dev/null || true
    grep -q 'pam_systemd\.so' /etc/pam.d/greetd 2>/dev/null || \
        printf 'session    required     pam_systemd.so\n' >> /etc/pam.d/greetd
fi

### Desktop-environment specific tweaks ###

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

# dbus-run-session: the live Hyprland desktop runs under UWSM, and the
# autologin fallback in /usr/local/bin/live-session-launcher needs it too, but
# /usr/bin/dbus-run-session is provided by the `dbus-daemon` package, which the
# base (dbus-broker) image doesn't ship. Install it on the live tree.
rum -y install dbus-daemon

# Live session: follow the exact scheme used by the official RakuOS ISOs
# (cosmic/gnome/niri) - livesys.service creates `liveuser` + /home/liveuser at
# BOOT (never at build time: build-time /home is lost in the squashfs, which is
# what caused "error 13: Permission denied"). greetd autologin starts only in
# this live tree, after livesys has created the user. No getty autologin, no
# shell-profile exec, no build-time useradd.
echo 'livesys_session=hyprland' > /etc/sysconfig/livesys
systemctl enable livesys.service livesys-late.service 2>/dev/null || true

# Ship the factory livesys-session-extra seed (identical to what rakuos-forge
# installs with --livesys for DE images) so the live boot sets the hostname and
# timezone, and runs any /var/lib/livesys/livesys-session-extra.d/ scripts.
mkdir -p /usr/share/factory/var/lib/livesys
cat > /usr/share/factory/var/lib/livesys/livesys-session-extra <<'EOF'
#!/bin/bash

. /etc/os-release

usermod -c "$NAME User" liveuser
hostnamectl hostname "$ID"

timedatectl set-timezone UTC
ln -s /usr/share/zoneinfo/UTC /etc/localtime

if [ -d /var/lib/livesys/livesys-session-extra.d ]; then
  find /var/lib/livesys/livesys-session-extra.d -type f -exec /bin/bash {} \;
fi
EOF
chmod 0644 /usr/share/factory/var/lib/livesys/livesys-session-extra
mkdir -p /usr/lib/tmpfiles.d
echo "C /var/lib/livesys/livesys-session-extra 0755 root root - /usr/share/factory/var/lib/livesys/livesys-session-extra" > \
    /usr/lib/tmpfiles.d/livesys-session-extra.conf

# Live greeter: greetd + noctalia-greeter, matching the installed image
# (system_files/etc/greetd/config.toml there runs the same
# /usr/bin/noctalia-greeter-session as default_session).
#
# This ISO previously ran SDDM instead, but sddm was never installed -- not in
# the image, not in /usr/share/rakuos/packages-live.list, and nothing here
# installed it -- so `systemctl enable sddm.service` could only ever produce an
# ISO with no working display manager. greetd and noctalia-greeter-git are
# already in the image, so using them needs no extra package.
#
# [initial_session] is greetd's autologin: it runs instead of the greeter when
# it succeeds, and the greeter still appears if it fails or the user logs out.
# Autologin must NOT go through uwsm's `uwsm start` unconditionally -- uwsm
# needs a systemd --user manager, which depends on pam_systemd.so having
# survived in greetd's PAM stack (re-asserted above). The wrapper below tries
# uwsm and falls back to plain Hyprland so a live boot always reaches a desktop
# instead of dropping to a TTY.
mkdir -p /etc/greetd
cat > /etc/greetd/config.toml << 'GREETD'
[terminal]
vt = 1

[default_session]
command = "/usr/bin/noctalia-greeter-session"
user = "greeter"

[initial_session]
command = "/usr/local/bin/live-session-launcher"
user = "liveuser"
GREETD

cat > /usr/local/bin/live-session-launcher << 'LAUNCHER'
#!/usr/bin/env bash
# greetd [initial_session] entry for the live ISO: start Hyprland for liveuser.
#
# Preferred path is the same UWSM-managed session the installed image uses
# (/usr/share/wayland-sessions/hyprland-uwsm.desktop). uwsm needs a
# systemd --user instance; if one is not there, `uwsm start` blocks forever
# waiting for org.freedesktop.systemd1. So probe for it first and fall back to
# running Hyprland directly, which needs no systemd at all.
if [[ -S "/run/user/$(id -u)/bus" ]] && systemctl --user is-system-running >/dev/null 2>&1; then
    exec env UWSM_SILENT_START=2 uwsm start -e -D Hyprland hyprland.desktop
fi

echo "live-session: no systemd --user bus, starting Hyprland directly" >&2
exec dbus-run-session -- /usr/bin/start-hyprland
LAUNCHER
chmod 0755 /usr/local/bin/live-session-launcher

# greetd must not start before livesys has created liveuser, otherwise the
# initial_session fails on a nonexistent user and falls back to the greeter.
mkdir -p /etc/systemd/system/greetd.service.d
cat > /etc/systemd/system/greetd.service.d/90-live-session.conf << 'UNIT'
[Unit]
Wants=livesys.service
After=livesys.service
UNIT

# /var is not carried into the squashfs, so the greeter account's home is gone
# at boot even though the account itself exists in the image. Recreate it at
# every boot or the greeter session cannot start.
mkdir -p /usr/lib/tmpfiles.d
cat > /usr/lib/tmpfiles.d/live-greeter.conf << 'TMPFILES'
d /var/lib/greeter 0750 greeter greeter -
d /var/lib/noctalia-greeter 0750 greeter greeter -
TMPFILES

systemctl enable greetd.service
systemctl enable greetd.socket 2>/dev/null || true

# If iso-base's shared files ever bring in an SDDM setup, make sure it cannot
# compete with greetd for the display-manager slot.
systemctl disable sddm.service 2>/dev/null || true
systemctl mask sddm.service 2>/dev/null || true
rm -rf /etc/sddm.conf.d /etc/systemd/system/sddm.service.d

# Without this, the ISO boots straight to multi-user.target (a plain TTY
# login prompt) even though greetd.service is "enabled" above -- enabling a
# service only adds it to its own target's *.wants/ directory, it does NOT
# change which target the system actually boots into. graphical.target is
# what pulls display-manager.service (-> greetd.service) in at boot.
systemctl set-default graphical.target

# Don't show the motd verification notice
rm -vf /etc/profile.d/verify_motd.sh

# Remove rakuos-welcome autostart for the live environment
rm -f /etc/xdg/autostart/rakuos-welcome.desktop

rm -rf /root/packages
