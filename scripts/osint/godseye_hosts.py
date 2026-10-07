#!/usr/bin/env python3
"""godseye_hosts — enumerate every host name present in the vendored GODSEYE
bundle, and keep that enumeration honest.

@decision DEC-PHASE12-045
@title GODSEYE on Orion-X: vendored static globe, posture-gated, hosts enumerated
@status accepted
@rationale GODSEYE is a live-API application. Every layer it draws comes from
  somewhere on the internet, and an operator on a hostile network is entitled
  to know exactly where before clicking anything. A hand-written list of
  "the APIs it uses" is a claim; it drifts the moment the bundle is
  re-vendored, and a drifted list is worse than none because it is believed.

  So the list is not hand-written. `extract_hosts()` reads the bytes that
  actually ship and recovers every host string in them. HOSTS.txt carries
  that machine-generated inventory between two markers, and
  tests/unit/test_godseye.sh fails if the inventory and the bundle disagree.
  Re-vendoring GODSEYE therefore cannot quietly add a host: the suite goes
  red and a human has to classify the new name.

  The prose above the markers is the part a human writes — which layer
  causes which request, and which of them are relays rather than origins.
  That part is a judgement and is signed as one.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

INVENTORY_BEGIN = "=== INVENTORY BEGIN (generated: scripts/osint/godseye_hosts.py --write) ==="
INVENTORY_END = "=== INVENTORY END ==="

# A host inside a URL literal. Deliberately permissive about what follows the
# scheme and strict about what counts as a name: the bundle is full of
# template fragments like `https://${base}/x` and `https://'` which are not
# hosts and must not be reported as if the deck would contact them.
_URL = re.compile(
    rb"https?://"
    rb"([A-Za-z0-9](?:[A-Za-z0-9._-]{0,251}[A-Za-z0-9])?)"
    rb"(?::(\d{1,5}))?"
)
_TLD = re.compile(r"^[A-Za-z]{2,}$")


# ===========================================================================
# PURE
# ===========================================================================

def extract_hosts(blob: bytes) -> set[str]:
    """Every syntactically valid host name appearing in a URL literal in `blob`.

    Pure, bytes-in / strings-out, so the test can feed it a fabricated buffer
    and know what the answer must be.
    """
    found: set[str] = set()
    for match in _URL.finditer(blob):
        host = match.group(1).decode("ascii", errors="ignore").strip(".").lower()
        port = match.group(2)
        if "." not in host:
            continue                        # localhost, bare template vars
        labels = host.split(".")
        if any(not label for label in labels):
            continue                        # "a..b"
        if not _TLD.match(labels[-1]):
            continue                        # "1.2.3.4" is not a name; "x.co" is
        if port:
            host = "%s:%s" % (host, port.decode("ascii"))
        found.add(host)
    return found


def parse_inventory(text: str) -> list[str]:
    """The host list recorded between the markers in HOSTS.txt."""
    try:
        body = text.split(INVENTORY_BEGIN, 1)[1].split(INVENTORY_END, 1)[0]
    except IndexError:
        return []
    return [ln.strip() for ln in body.splitlines() if ln.strip()]


def render_inventory(hosts: list[str]) -> str:
    return "%s\n%s\n%s" % (INVENTORY_BEGIN, "\n".join(hosts), INVENTORY_END)


def splice_inventory(text: str, hosts: list[str]) -> str:
    """Replace the generated block, leaving every hand-written word alone."""
    head, _, rest = text.partition(INVENTORY_BEGIN)
    _, _, tail = rest.partition(INVENTORY_END)
    return head + render_inventory(hosts) + tail


# ===========================================================================
# IMPURE
# ===========================================================================

def scan_tree(root: Path) -> list[str]:
    """Every host in every byte that ships under `root`, sorted.

    Every file, not a chosen subset: a host hidden in a font or a glTF is
    still a host, and choosing which files to look at is how an audit starts
    lying to itself.
    """
    hosts: set[str] = set()
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        try:
            hosts |= extract_hosts(path.read_bytes())
        except OSError as exc:
            sys.stderr.write("[godseye-hosts] cannot read %s: %s\n" % (path, exc))
            raise
    return sorted(hosts)


def main(argv: list[str] | None = None) -> int:
    here = Path(__file__).resolve().parent
    default_root = here.parent.parent / (
        "iso/config/includes.chroot/opt/orionx/osint/godseye")
    parser = argparse.ArgumentParser(
        prog="godseye_hosts",
        description="Enumerate the hosts present in the vendored GODSEYE bundle.")
    parser.add_argument("--root", default=str(default_root),
                        help="the godseye/ directory (default: %(default)s)")
    parser.add_argument("--hosts-file", default="",
                        help="HOSTS.txt (default: <root>/HOSTS.txt)")
    parser.add_argument("--check", action="store_true",
                        help="exit 1 if HOSTS.txt disagrees with the bundle")
    parser.add_argument("--write", action="store_true",
                        help="rewrite the generated inventory block in place")
    parser.add_argument("--list", action="store_true",
                        help="print the hosts found in the bundle and exit")
    args = parser.parse_args(argv)

    root = Path(args.root)
    app = root / "app"
    if not app.is_dir():
        sys.stderr.write(
            "[godseye-hosts] no vendored bundle at %s\n"
            "                Nothing to enumerate. The GODSEYE surface is not "
            "installed on this deck.\n"
            "                Remedy: orionx-osint --check\n" % app)
        return 2
    hosts = scan_tree(app)

    if args.list:
        print("\n".join(hosts))
        return 0

    hosts_file = Path(args.hosts_file) if args.hosts_file else root / "HOSTS.txt"
    if not hosts_file.is_file():
        sys.stderr.write("[godseye-hosts] missing %s\n" % hosts_file)
        return 2
    text = hosts_file.read_text(encoding="utf-8")

    if args.write:
        hosts_file.write_text(splice_inventory(text, hosts), encoding="utf-8")
        print("[godseye-hosts] wrote %d hosts into %s" % (len(hosts), hosts_file))
        return 0

    recorded = parse_inventory(text)
    added = sorted(set(hosts) - set(recorded))
    gone = sorted(set(recorded) - set(hosts))
    if not added and not gone and recorded == hosts:
        print("[godseye-hosts] ok: %d hosts, inventory matches the shipped bundle"
              % len(hosts))
        return 0
    print("[godseye-hosts] HOSTS.txt does not describe the bundle that ships.")
    for host in added:
        print("  IN BUNDLE, NOT RECORDED: %s" % host)
    for host in gone:
        print("  RECORDED, NOT IN BUNDLE: %s" % host)
    if not added and not gone:
        print("  the inventory is not in sorted order")
    print("  Consequence: the host list an operator reads before opening "
          "GODSEYE is not the list GODSEYE would contact.")
    print("  Remedy: python3 scripts/osint/godseye_hosts.py --write   "
          "# then classify every new name in the prose above the markers")
    # A mismatch fails in EVERY mode, not only --check: a report that the
    # host list is wrong must never exit 0 (the old `1 if check else 1` said
    # the same thing twice; python P2-10 / RUF034).
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
