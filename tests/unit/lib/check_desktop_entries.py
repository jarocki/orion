#!/usr/bin/env python3
"""Check the Orion menu and autostart entries the image ships.

Used by tests/unit/test_operator_surfaces.sh (DEC-PHASE12-125). Prints
"OK <n> entries" or one "FAIL ..." line per problem.

argv: APPS_DIR INC_ROOT HOOK_0700 APP_PY "MESH_CMDS" AUTOSTART_DIR
"""
import configparser
import os
import re
import shlex
import sys
import xml.etree.ElementTree as ET

apps, inc, hook, appy, mesh_cmds, autostart = sys.argv[1:7]
mesh_cmds = set(mesh_cmds.split())
# /usr/bin names wired by any live hook's symlink map (0700 is the authority
# for the core tools; 0702 wires the music tools the same way).
hook_dir = os.path.dirname(hook)
script_map = set()
for h in os.listdir(hook_dir):
    hp = os.path.join(hook_dir, h)
    if not os.path.isfile(hp):  # live-build ships dangling symlinks here
        continue
    src = open(hp, encoding="utf-8", errors="replace").read()
    script_map |= set(re.findall(r'\["([^"]+)"\]="(?:/opt/orionx/|\$MUSIC_DIR/)', src))
tabs = dict(re.findall(r'\("(\w+)", "([^"]+)", "[^"]*", \w+\.build_section\)',
                       open(appy, encoding="utf-8").read()))
icons = os.path.join(inc, "usr/share/icons/Orion-X-Icons/scalable/orionx")
RETIRED = re.compile(r"Control Center|Investigation Surface|IR Tools", re.I)
JARGON = re.compile(r"\bPhase \d+\b|DEC-PHASE|\bW\d+-\d+\b")
# Programs Debian packages provide (not Orion-X scripts).
SYSTEM = {"xfce4-terminal", "wireshark", "matrix-commander", "sh", "bash"}
# The surfaces an operator must tell apart at a glance in the menu (UX-44).
PRIMARY = {"orionx-cockpit.desktop", "orionx-control-center.desktop", "orionx-osint.desktop"}
out, names = [], {}


def on_path(cmd):
    cmd = os.path.basename(cmd)
    return (cmd in script_map or cmd in SYSTEM
            or os.path.exists(os.path.join(inc, "usr/bin", cmd)))


def read(path):
    cp = configparser.ConfigParser(interpolation=None, strict=False)
    cp.optionxform = str
    cp.read(path, encoding="utf-8")
    return cp["Desktop Entry"]


if not tabs:
    out.append("FAIL could not read the Cockpit tab table from app.py")

count = 0
for f in sorted(os.listdir(apps)):
    e = read(os.path.join(apps, f))
    if "X-Orion" not in e.get("Categories", ""):
        continue
    count += 1
    name, comment, icon, exe = (e.get(k, "") for k in ("Name", "Comment", "Icon", "Exec"))
    if not (name and icon and exe):
        out.append(f"FAIL {f}: missing Name/Icon/Exec")
        continue
    names.setdefault(name, []).append(f)
    if RETIRED.search(name + " " + comment):
        out.append(f"FAIL {f}: retired surface name in Name/Comment: {name!r} / {comment!r}")
    if JARGON.search(comment):
        out.append(f"FAIL {f}: development jargon in the operator tooltip: {comment!r}")
    if icon.startswith("/"):
        if not os.path.exists(os.path.join(inc, icon.lstrip("/"))):
            out.append(f"FAIL {f}: Icon file {icon} is not shipped")
    elif icon.startswith("orionx-"):
        try:
            ET.parse(os.path.join(icons, icon + ".svg"))
        except Exception as ex:  # noqa: BLE001 — report any parse/missing error
            out.append(f"FAIL {f}: Icon {icon} has no valid SVG in Orion-X-Icons ({ex})")
    if f in PRIMARY and not icon.startswith("orionx-"):
        out.append(f"FAIL {f}: primary surface uses a shared generic icon ({icon}); give it its own Orion-X-Icons glyph")
    argv = shlex.split(exe)
    if argv[0] == "xfce4-terminal":
        inner = argv[argv.index("-e") + 1] if "-e" in argv else ""
        # "bash -c '<cmd>; exec bash'" → the words of <cmd>
        inner = shlex.split(shlex.split(inner)[-1]) if inner else []
        inner = [w.rstrip(";") for w in inner]
        if inner[:1] == ["sudo"]:
            inner = inner[1:]
        if inner and inner[0] == "orionx-mesh":
            if len(inner) < 2 or inner[1] not in mesh_cmds:
                out.append(f"FAIL {f}: runs orionx-mesh without a valid subcommand ({exe})")
            elif "sudo orionx-mesh" not in exe:
                out.append(f"FAIL {f}: orionx-mesh refuses to run without root; Exec lacks sudo")
        if inner and not on_path(inner[0]):
            out.append(f"FAIL {f}: Exec runs {inner[0]}, which nothing installs")
    elif not on_path(argv[0]):
        out.append(f"FAIL {f}: Exec {argv[0]} is not installed by the image")
    if "--tab" in argv:
        tab = argv[argv.index("--tab") + 1]
        if tab not in tabs:
            out.append(f"FAIL {f}: --tab {tab} is not a Cockpit tab ({sorted(tabs)})")
        else:
            if tabs[tab] not in name:
                out.append(f"FAIL {f}: opens the {tabs[tab]} tab but its Name says {name!r}")
            others = [lbl for k, lbl in tabs.items() if k != tab]
            if any(lbl in comment for lbl in others) and tabs[tab] not in comment:
                out.append(f"FAIL {f}: Comment lists other tabs but not the one it opens: {comment!r}")

for n, fs in names.items():
    if len(fs) > 1:
        out.append(f"FAIL two menu entries share the Name {n!r}: {fs}")

for f in sorted(os.listdir(autostart)):
    e = read(os.path.join(autostart, f))
    if RETIRED.search(e.get("Name", "") + " " + e.get("Comment", "")):
        out.append(f"FAIL autostart/{f}: names a retired surface: {e.get('Name')!r}")

print("\n".join(out) if out else f"OK {count} entries")
