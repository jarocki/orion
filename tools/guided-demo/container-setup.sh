#!/bin/bash
# Runs INSIDE the render container (debian:trixie-slim) as root, once.
# Mirrors the ISO layout from the repo mounted read-only at /repo so the
# recorded applications are the shipped ones, then prepares the demo user,
# the virtual XFCE session prerequisites, and the offline narration voice.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "[setup] apt packages"
apt-get update -q
apt-get install -y -q --no-install-recommends \
    xvfb x11-utils x11-xserver-utils xauth xdotool imagemagick ffmpeg \
    python3 python3-gi python3-gi-cairo gir1.2-gtk-3.0 gir1.2-gdkpixbuf-2.0 \
    python3-pip python3-venv python3-yaml python3-markdown python3-pymdownx python3-pygments \
    fonts-dejavu fonts-hack fonts-noto-core papirus-icon-theme adwaita-icon-theme \
    firefox-esr xfce4-session xfwm4 xfce4-panel xfdesktop4 xfce4-settings \
    xfce4-genmon-plugin xfce4-terminal thunar mate-polkit dbus-x11 procps iproute2 sudo \
    tshark \
    python3-cmd2 python3-rich python3-sqlalchemy python3-httpx python3-pydantic \
    python3-tomli-w python3-requests python3-pytz python3-simplejson python3-prompt-toolkit \
    >/dev/null
pip3 install --break-system-packages -q pyfiglet stix2 piper-tts volatility3

echo "[setup] mirror ISO layout from /repo"
mkdir -p /opt/orionx/scripts /opt/orionx/theme /opt/orionx/nucleotide /usr/share/orionx \
         /run/orionx /var/log/orionx /usr/share/doc/orionx /etc/xdg/menus/applications-merged
cp -a /repo/scripts/. /opt/orionx/scripts/
cp -a /repo/iso/config/includes.chroot/opt/orionx/theme/. /opt/orionx/theme/
cp -a /repo/iso/config/includes.chroot/usr/share/themes/. /usr/share/themes/
cp -a /repo/iso/config/includes.chroot/usr/share/icons/. /usr/share/icons/
cp -a /repo/iso/config/includes.chroot/usr/share/pixmaps/. /usr/share/pixmaps/
cp -a /repo/iso/config/includes.chroot/usr/share/plymouth /usr/share/
cp -a /repo/iso/config/includes.chroot/usr/share/desktop-directories/. /usr/share/desktop-directories/
cp -a /repo/iso/config/includes.chroot/etc/xdg/menus/applications-merged/. /etc/xdg/menus/applications-merged/
cp -a /repo/iso/config/includes.chroot/usr/share/orionx/. /usr/share/orionx/ 2>/dev/null || true
# From the built image (extracted by build.sh): Orion .desktop entries + nucleotide lookup table.
[ -d /work/image/applications ] && cp /work/image/applications/orionx-*.desktop /usr/share/applications/
[ -d /work/image/nucleotide ] && cp -a /work/image/nucleotide/. /opt/orionx/nucleotide/

echo "[setup] skel config exactly as the ISO seeds it (0100 hook writes only /etc/skel)"
bash /repo/iso/config/hooks/normal/0100-create-user.hook.chroot >/tmp/0100.log 2>&1

echo "[setup] user guide HTML (0810 hook)"
cp /repo/docs/User_Guide.md /usr/share/doc/orionx/ && cp -a /repo/docs/images /usr/share/doc/orionx/
bash /repo/iso/config/hooks/live/0810-render-user-guide.hook.chroot >/dev/null

echo "[setup] command symlinks (as 0700 SCRIPT_MAP)"
for pair in orionx-control-center:control_center/orionx-control-center orionx-cockpit:cockpit/orionx-cockpit \
            orionx-event:rain/orionx-event nucleotide:nucleotide/nucleotide-cli \
            orionx-nucleotide-watch:nucleotide/orionx-nucleotide-watch ap:pivotglass/ap pivotglass:pivotglass/ap \
            nebula:nebula/nebula; do
    ln -sf "/opt/orionx/scripts/${pair#*:}" "/usr/bin/${pair%%:*}"
    chmod +x "/opt/orionx/scripts/${pair#*:}"
done
chmod +x /opt/orionx/scripts/set-wallpaper.sh

echo "[setup] demo user + event bus"
id orionx-operator >/dev/null 2>&1 || adduser --disabled-password --gecos "Orion-X Operator" orionx-operator >/dev/null
touch /run/orionx/events.jsonl && chmod 0666 /run/orionx/events.jsonl && chmod 0777 /run/orionx /var/log/orionx /work
echo 'ISO_VERSION=v2.2.0-beta' > /etc/orionx-version

echo "[setup] Nebula runtime stand-in state (UI only — no model runs here)"
D=fb8a8b68d419c3a22f70436796ca5eb38b4f49bd787c4683ffb613aa771957d9
mkdir -p /opt/orionx/nebula/models/blobs
[ -f "/opt/orionx/nebula/models/blobs/sha256-$D" ] || truncate -s 1929903264 "/opt/orionx/nebula/models/blobs/sha256-$D"
printf '%s  blobs/sha256-%s\n' "$D" "$D" > /opt/orionx/nebula/models/MANIFEST.sha256
printf 'NEBULA_INTEGRITY=OK\nNEBULA_INTEGRITY_DETAIL=all 2 model file(s) verified OK\nNEBULA_INTEGRITY_TS=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S)" > /run/orionx/nebula-integrity.status

echo "[setup] narration voice"
mkdir -p /work/voices && (cd /work/voices && python3 -m piper.download_voices en_US-lessac-medium >/dev/null 2>&1)
ls /work/voices/en_US-lessac-medium.onnx >/dev/null
echo "[setup] done"
