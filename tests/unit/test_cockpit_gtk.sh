#!/usr/bin/env bash
# The Cockpit under a real GTK 3 main loop on a virtual X display.
#
# Runs locally when python3-gi + xvfb-run are installed (the deck, CI on
# Debian); otherwise inside the headless image built from
# tests/unit/gtk-headless.Dockerfile when it exists:
#   docker build --platform linux/amd64 -t orionx-gtk-headless:trixie -f tests/unit/gtk-headless.Dockerfile tests/unit
# and SKIPs (exit 0, loudly) when neither is available. The repo is mounted
# read-only in the container, so the run cannot litter it.
#
# What it proves (QA round 1, A1): behaviour that only exists with a live
# widget tree — settings writes that fail revert the control and say why;
# hidden tabs do not poll; the LIVE layout fits the 1366x768 reference deck;
# no retired surface names reach the screen.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${ORIONX_GTK_IMAGE:-orionx-gtk-headless:trixie}"
CHECK="$ROOT/tests/unit/cockpit_gtk_checks.py"

if python3 -c 'import gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk' 2>/dev/null \
   && command -v xvfb-run >/dev/null 2>&1; then
    PYTHONDONTWRITEBYTECODE=1 timeout 300 xvfb-run -a -s "-screen 0 1366x768x24" python3 -u "$CHECK" "$ROOT"
    exit $?
fi
if command -v docker >/dev/null 2>&1 && docker image inspect "$IMAGE" >/dev/null 2>&1; then
    # Non-root, so the "unwritable config" cases are really unwritable.
    docker run --rm --platform linux/amd64 --user 1000:1000 -v "$ROOT:/repo:ro" -e PYTHONDONTWRITEBYTECODE=1 \
        "$IMAGE" timeout 300 xvfb-run -a -s "-screen 0 1366x768x24" python3 -u /repo/tests/unit/cockpit_gtk_checks.py /repo
    exit $?
fi
echo "  SKIP: no python3-gi/xvfb-run here and no $IMAGE image — GTK behaviour NOT verified"
echo "        build it: docker build --platform linux/amd64 -t $IMAGE -f tests/unit/gtk-headless.Dockerfile tests/unit"
exit 0
