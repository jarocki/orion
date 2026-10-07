#!/usr/bin/env python3
"""Operator docs describe the current release and the current UI.

Used by tests/unit/test_operator_surfaces.sh (DEC-PHASE12-131). Prints
"OK ..." or one "FAIL file:line: ..." per problem.

argv: REPO_ROOT RELEASE (e.g. v3.0.0)

Historical references are allowed (the v2.2.0-beta shipped, the rc builds
existed); what is forbidden is text that presents the current image as a
beta/rc, or sends the operator to a surface that no longer exists, or a
command that cannot work as written.
"""
import os
import re
import sys

root, release = sys.argv[1], sys.argv[2]
FILES = ["README.md", "docs/User_Guide.md", "docs/SUPPORT.md",
         "docs/orionx-diag.md", "docs/orionx-imager.md"]
RULES = [
    (re.compile(r"\bv2\.2\.0-rc[0-9]+\b"), "names an rc build as current (rc history belongs in CHANGELOG.md)"),
    (re.compile(r"\b(?:This is a beta|is a beta\b|In this beta|for the beta to start|the beta's bootloader)", re.I),
     "presents the current release as a beta"),
    (re.compile(r"Control Center(?:'s)? (?:→|\*\*|IR Tools)|◈ ?COCKPIT|IR Tools tab"),
     "navigates through a retired surface (the Control Center is the Cockpit's tabs)"),
    (re.compile(r"Investigation surface\b(?! /)"), "uses the retired name for the Orion Workbench"),
    (re.compile(r"(?<!sudo )(?<![\w-])orionx-mesh (?:status|peers|join|leave)\b"),
     "runs orionx-mesh without sudo (it refuses to run without root)"),
    (re.compile(r"(?<!sudo )(?<![\w/.-])orionx-diag(?: --(?:json|category))?\s*(?:$|#|>)", re.M),
     "runs orionx-diag without sudo (the systemd/AppArmor checks are then skipped)"),
    (re.compile(r"nothing forwards them to the event bus"), "denies Suricata→bus forwarding, which orionx-postured does"),
    (re.compile(r"no outbound network; DEC-PHASE10-011"), "claims ollama's AppArmor profile blocks egress (it allows inet)"),
    (re.compile(r"blank = passwordless|keep the account passwordless|press Enter if you left it blank"),
     "says the account can be passwordless (its default password is `live`)"),
]
# Lines that are explicitly historical may name old things.
HISTORY = re.compile(r"\((?:then called|called IR Tools before|it used to be called|on the old v2\.2\.0-beta|Builds before rc6)|"
                     r"used to be the separate Control Center|formerly the Control Center|replaced the separate Control Center|"
                     r"recorded on v2\.2\.0-beta|v2\.2\.0-rc5:\*\*|Later release candidates|old name, kept|"
                     r"rc5 – rc9|from rc5")
out, checked = [], 0
for rel in FILES:
    path = os.path.join(root, rel)
    fence = False
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        checked += 1
        if HISTORY.search(line):
            continue
        for rx, why in RULES:
            if rx.search(line):
                out.append(f"FAIL {rel}:{n}: {why}: {line.strip()[:110]}")
readme = open(os.path.join(root, "README.md"), encoding="utf-8").read()
if f"**Version:** {release}" not in readme:
    out.append(f"FAIL README.md: the Version line does not name {release}")
if "## Known issues" not in readme:
    out.append("FAIL README.md: no '## Known issues' section")
else:
    known = readme.split("## Known issues", 1)[1].split("\n## ", 1)[0]
    for issue in ("#98", "#85"):
        if issue not in known:
            out.append(f"FAIL README.md Known issues: does not list {issue}")
guide = open(os.path.join(root, "docs/User_Guide.md"), encoding="utf-8").read()
slots = re.findall(r"<!--orionx:release-->([^<]*)<!--/orionx:release-->", guide)
if not slots or set(slots) != {release}:
    out.append(f"FAIL docs/User_Guide.md: release slots say {sorted(set(slots))}, want [{release!r}]")
print("\n".join(out) if out else f"OK {checked} lines in {len(FILES)} docs; README + guide name {release}")
