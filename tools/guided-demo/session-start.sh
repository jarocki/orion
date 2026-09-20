#!/bin/bash
# Runs INSIDE the render container as root: brings up the virtual display, a
# real XFCE session for the demo user (seeded skel config, Phoenix wallpaper,
# branded panel with the live genmon widgets), a few events on the bus so the
# panel/cockpit have something to show, the Nebula runtime stand-in, and the
# Pivotglass web UI with its offline learning case loaded.
set -uo pipefail
DISPLAY_NUM="${1:-:99}"

pkill -f fake-ollama.py 2>/dev/null; pkill -x Xvfb 2>/dev/null; sleep 1
mkdir -p /tmp/xdg && chmod 700 /tmp/xdg && chown orionx-operator /tmp/xdg
nohup python3 /repo/tools/guided-demo/fake-ollama.py >/tmp/fake-ollama.log 2>&1 &

# Stand-ins for the two host probes the Control Center's Awareness page makes
# (there is no systemd or NetworkManager inside the container). They answer
# exactly what the reference deck answers when healthy — the same two units
# awareness.py checks — and nothing else. Disclosed in the transcript.
mkdir -p /opt/demo-stubs
cat > /opt/demo-stubs/systemctl <<'EOF'
#!/bin/sh
case "$1 $2" in
  "is-active nebula-runtime.service"|"is-active orionx-firewall.service") echo active; exit 0 ;;
  "is-active "*) echo inactive; exit 3 ;;
  *) exit 1 ;;
esac
EOF
cat > /opt/demo-stubs/nmcli <<'EOF'
#!/bin/sh
# nmcli -t -f NAME,STATE connection show --active
echo "biarritz:activated"
EOF
chmod +x /opt/demo-stubs/*
grep -q demo-stubs /home/orionx-operator/.profile 2>/dev/null || echo 'export PATH=/opt/demo-stubs:$PATH' >> /home/orionx-operator/.profile

su - orionx-operator -c "export XDG_RUNTIME_DIR=/tmp/xdg DISPLAY=$DISPLAY_NUM
  Xvfb $DISPLAY_NUM -screen 0 1280x720x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
  sleep 2
  nohup dbus-run-session -- startxfce4 >/tmp/xfce.log 2>&1 &
  sleep 12
  # Xvfb's output is named 'screen' (XFCE 4.20 keys backdrops by connector).
  for m in screen 0; do
    xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor\$m/workspace0/last-image -n -t string -s /opt/orionx/theme/wallpapers/orionx-phoenix-wallpaper.png
    xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor\$m/workspace0/image-style -n -t int -s 5
  done
  pkill -x xfdesktop; sleep 1; (nohup xfdesktop >/dev/null 2>&1 &)
  for s in info notice warning critical; do orionx-event --source demo --category scan --severity \$s \"demo \$s event\" >/dev/null 2>&1; done
  # Firefox: no first-run/privacy tab, and no 'reduced sandbox protection' bar
  # (the container has no unprivileged user namespaces) in the recording.
  mkdir -p ~/.mozilla/firefox/demo.default && cat > ~/.mozilla/firefox/profiles.ini <<'INI'
[Profile0]
Name=demo
IsRelative=1
Path=demo.default
Default=1
[General]
StartWithLastProfile=1
Version=2
INI
  cat > ~/.mozilla/firefox/demo.default/user.js <<'JS'
user_pref("security.sandbox.warn_unprivileged_namespaces", false);
user_pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);
user_pref("datareporting.policy.firstRunURL", "");
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.urlbar.suggest.topsites", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
JS
  cd /tmp && (nohup ap web >/tmp/ap.log 2>&1 &)
  sleep 8
  python3 - <<'PY'
import json, urllib.request
req = urllib.request.Request('http://127.0.0.1:8765/api/command',
    data=json.dumps({'command': 'workspace learn release-tour'}).encode(),
    headers={'Content-Type': 'application/json', 'Origin': 'http://127.0.0.1:8765'})
try:
    print('pivotglass learning case:', urllib.request.urlopen(req, timeout=120).status)
except Exception as e:
    print('pivotglass learn failed:', e)
PY
  sleep 3; import -window root /tmp/session-ready.png && echo 'session ready'
"
