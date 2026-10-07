#!/usr/bin/env python3
"""Check the seeded XFCE panel and the Cockpit's desktop/panel launchers.

Used by tests/unit/test_operator_surfaces.sh (DEC-PHASE12-128). Prints
"OK ..." or one "FAIL ..." line per problem.

argv: PANEL_XML HOOK_0100 HOOK_0700
"""
import re
import sys
import xml.etree.ElementTree as ET

panel_xml, hook0100, hook0700 = sys.argv[1:4]
src0100 = open(hook0100, encoding="utf-8").read()
src0700 = open(hook0700, encoding="utf-8").read()
out = []

root = ET.parse(panel_xml).getroot()


def prop(node, name):
    for p in node.findall("property"):
        if p.get("name") == name:
            return p
    return None


panel = prop(prop(root, "panels"), "panel-1")
order = [int(v.get("value")) for v in prop(panel, "plugin-ids").findall("value")]
plugins = {}
for p in prop(root, "plugins").findall("property"):
    pid = int(p.get("name").split("-")[1])
    plugins[pid] = p
kinds = [plugins[i].get("value") if i in plugins else "MISSING" for i in order]
if "MISSING" in kinds:
    out.append(f"FAIL plugin-ids lists an id with no plugin definition: {order}")

# 1. A Cockpit launcher sits right after the applications menu (UX-08).
launchers = [i for i in order if plugins.get(i) is not None and plugins[i].get("value") == "launcher"]
cockpit_id = None
for i in launchers:
    items = prop(plugins[i], "items")
    vals = [v.get("value") for v in items.findall("value")] if items is not None else []
    if "orionx-cockpit.desktop" in vals:
        cockpit_id = i
if cockpit_id is None:
    out.append("FAIL no panel launcher plugin lists orionx-cockpit.desktop")
else:
    pos = order.index(cockpit_id)
    if pos == 0 or kinds[pos - 1] != "applicationsmenu":
        out.append(f"FAIL the Cockpit launcher is not right after the applications menu: {kinds}")
    # The launcher reads launcher-<id>/<item>; 0700 must derive exactly that
    # file from the menu entry (one source, derived copies).
    want = f"/etc/skel/.config/xfce4/panel/launcher-{cockpit_id}"
    if want not in src0700:
        out.append(f"FAIL 0700 does not derive the menu entry into {want}/ (the launcher would be empty)")

# 2. The genmon widgets are separated, not run together (UX-31).
for a, b in zip(kinds, kinds[1:]):
    if a == "genmon" and b == "genmon":
        out.append(f"FAIL two genmon widgets are adjacent with no separator: {kinds}")
        break

# 3. genmon ids still match the per-plugin .rc files 0100 writes.
genmon_ids = sorted(i for i in order if plugins.get(i) is not None and plugins[i].get("value") == "genmon")
rc_ids = sorted(int(x) for x in re.findall(r"^_orionx_genmon_rc (\d+) ", src0100, re.M))
if genmon_ids != rc_ids:
    out.append(f"FAIL genmon plugin ids {genmon_ids} != genmon-<id>.rc ids {rc_ids}")

# 4. The Cockpit has a desktop icon, derived from the same menu entry.
if "/etc/skel/Desktop" not in src0700 or "orionx-cockpit.desktop" not in src0700:
    out.append("FAIL 0700 does not derive a Cockpit desktop icon into /etc/skel/Desktop")

print("\n".join(out) if out else f"OK panel order: {' → '.join(kinds)}")
