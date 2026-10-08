#!/usr/bin/env bash
# rootfs-session.sh — start the ISO's own desktop inside the capture container.
#
# Runs as root inside `orionx-capture:<tag>` (the ISO squashfs imported as a
# Docker image, plus Xvfb/xdotool/ffmpeg). Does what live-boot + live-config +
# LightDM autologin do on the deck, in the smallest honest form:
#   * creates the live user exactly as live-config does (orionx-operator,
#     password "live", groups sudo/audio/video, home from /etc/skel),
#   * starts the system D-Bus, /run/orionx (tmpfs on the deck), orionx-postured
#     and orionx-rain's bus file, so the Cockpit reads real daemon state,
#   * starts Xvfb :0 at 1920x1080 and PulseAudio with a null sink whose
#     monitor the recorder captures (that is how the deck's own sounds get in),
#   * runs the user's XFCE session (startxfce4) from the image's skeleton.
# Usage: rootfs-session.sh [WIDTHxHEIGHT]
set -euo pipefail
RES="${1:-1920x1080}"
U=orionx-operator

if ! id "$U" >/dev/null 2>&1; then
    useradd -m -k /etc/skel -s /bin/bash -G sudo,audio,video,netdev,plugdev "$U" 2>/dev/null \
        || useradd -m -k /etc/skel -s /bin/bash -G sudo,audio,video "$U"
    echo "$U:live" | chpasswd
    echo "$U ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/live-capture   # live-config does the same
    chmod 0440 /etc/sudoers.d/live-capture
fi
UID_N="$(id -u "$U")"

mkdir -p /run/dbus /run/orionx "/run/user/$UID_N" /var/log/orionx /var/lib/orionx
chown "$U:$U" "/run/user/$UID_N"; chmod 0700 "/run/user/$UID_N"
chmod 0755 /run/orionx; touch /run/orionx/events.jsonl; chmod 0666 /run/orionx/events.jsonl
[ -S /run/dbus/system_bus_socket ] || dbus-daemon --system --fork
cp -f /etc/orionx-version /run/orionx/ 2>/dev/null || true

# The deck's firewall, exactly as orionx-firewall.service applies it (needs --cap-add NET_ADMIN).
nft -f /etc/nftables.conf 2>/var/log/orionx/nft.capture.log || echo "WARN: nftables.conf not applied (see nft.capture.log)"

# Root daemons the Cockpit reads (best effort: in a container some inputs are absent).
if [ -x /usr/bin/orionx-postured ]; then
    nohup /usr/bin/orionx-postured >/var/log/orionx/postured.capture.log 2>&1 &
fi

Xvfb :0 -screen 0 "${RES}x24" -nolisten tcp -ac +extension RANDR >/var/log/orionx/xvfb.log 2>&1 &
for _ in $(seq 1 50); do [ -S /tmp/.X11-unix/X0 ] && break; sleep 0.2; done

cat > /tmp/session.sh <<EOS
export DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/$UID_N XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=XFCE
pulseaudio --start --exit-idle-time=-1 --log-target=stderr >/tmp/pulse.log 2>&1 || true
pactl load-module module-null-sink sink_name=deck sink_properties=device.description=deck >/dev/null 2>&1 || true
pactl set-default-sink deck >/dev/null 2>&1 || true
exec dbus-run-session -- sh -c 'env | grep -E "^DBUS_SESSION_BUS_ADDRESS=" > /tmp/session.env; exec startxfce4' >/tmp/xfce.log 2>&1
EOS
chmod 0755 /tmp/session.sh
su - "$U" -c "nohup /tmp/session.sh >/dev/null 2>&1 &"

for _ in $(seq 1 120); do
    su - "$U" -c "DISPLAY=:0 xwininfo -root -tree 2>/dev/null" | grep -q '"xfce4-panel"' && break
    sleep 1
done
echo "SESSION-UP"
