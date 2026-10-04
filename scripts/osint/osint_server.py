#!/usr/bin/env python3
"""osint_server — the Orion-X investigation surface, served on loopback.

This module is the single authority for the server. /usr/bin/orionx-osint is
a three-line entrypoint that imports main() from here, following the
nebula-mcp precedent (DEC-PHASE12-025): hook 0700 owns PATH symlinks and is
not edited by this slice, so the entrypoint ships as a real file via
includes.chroot rather than as a second symlink authority.

@decision DEC-PHASE12-043
@title Local OSINT surface: launcher page, vendored CyberChef, local pew-pew map
@status accepted
@rationale Three things on this deck are web pages that must work with no
  network: the OSINT launcher, the vendored CyberChef, and the pew-pew map.
  None of them can be opened as file://. CyberChef constructs Web Workers and
  browsers refuse to do that from a file:// origin; the launcher and the map
  fetch their data as JSON and file:// fetch is blocked by the same-origin
  rules. So they need an origin, and the smallest honest one is a stdlib
  http.server bound to 127.0.0.1 that the operator starts and stops.

  It binds loopback only, never 0.0.0.0 — this is a deck that boots on
  networks someone already believes are compromised, and an attack map
  serving the deck's own detection history to the LAN would be a gift.

  It also answers two questions the pages cannot answer from inside the
  browser: what threat posture the deck is in, and whether there is a
  default route at all. Both decide whether an off-deck link may be offered,
  and both are read from local state — this process never reaches out to
  the network to find out whether the network is there.
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import socketserver
import subprocess
import sys
import threading
import time
import webbrowser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pewpew_feed  # noqa: E402

# --- Where things are -------------------------------------------------------
DEFAULT_ROOT = Path(os.environ.get("ORIONX_OSINT_ROOT", "/opt/orionx/osint"))
BUS = Path(os.environ.get("ORIONX_EVENT_LOG", pewpew_feed.EVENT_LOG))
POSTURE_STATUS = Path(os.environ.get("ORIONX_POSTURE_STATUS",
                                     "/run/orionx/posture-status.json"))
PROC_ROUTE = Path(os.environ.get("ORIONX_PROC_ROUTE", "/proc/net/route"))
PROC_ROUTE6 = Path(os.environ.get("ORIONX_PROC_ROUTE6", "/proc/net/ipv6_route"))

HOST = "127.0.0.1"
DEFAULT_PORT = 8787
PORT_TRIES = 8

# Tier 2 is Deception: decoys are live on a network the operator has declared
# hostile. Reaching out to a public OSINT site from that network announces
# this deck to it. The launcher honours this; it is declared here, once.
OUTBOUND_BLOCKED_TIERS = ("2",)

# Bus reads are bounded. The spool is tmpfs and normally small, but a flood
# must not make this handler allocate the whole thing.
BUS_TAIL_BYTES = 2 * 1024 * 1024


# ===========================================================================
# PURE: what the deck can honestly say about itself
# ===========================================================================

def read_default_route(text4: str, text6: str = "") -> dict[str, object]:
    """Is there a default route? Parsed from /proc, never probed over the wire.

    This answers "is this deck plugged into anything", which is NOT the same
    as "the internet is reachable". The UI must not claim the stronger thing,
    so the key is called `default_route`, not `online`.
    """
    iface = None
    for line in str(text4).splitlines()[1:]:
        fields = line.split()
        # Iface Destination Gateway Flags RefCnt Use Metric Mask ...
        if len(fields) >= 8 and fields[1] == "00000000":
            iface = fields[0]
            break
    v6 = False
    for line in str(text6).splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[0] == "0" * 32 and fields[1] == "00":
            v6 = True
            break
    return {"default_route": bool(iface) or v6,
            "interface": iface, "ipv6_default": v6}


def read_posture(text: str | None) -> dict[str, object]:
    """Tier + label from posture-status.json, fail-closed.

    Unreadable, missing or corrupt means posture UNKNOWN — and unknown
    blocks outbound links. The alternative (assume Tier 0, open the links)
    would mean a parse error silently lowers the deck's shields.
    """
    if not text:
        return {"tier": None, "label": "unknown",
                "known": False, "reason": "posture-status.json not readable",
                "outbound_allowed": False}
    try:
        data = json.loads(text)
    except (ValueError, TypeError):
        return {"tier": None, "label": "unknown", "known": False,
                "reason": "posture-status.json is not valid JSON",
                "outbound_allowed": False}
    tier = str(data.get("tier", "")).strip()
    if tier not in ("0", "1", "2"):
        return {"tier": None, "label": "unknown", "known": False,
                "reason": "posture-status.json has no recognised tier",
                "outbound_allowed": False}
    return {
        "tier": tier,
        "label": str(data.get("label") or "Tier " + tier),
        "known": True,
        "reason": "",
        "outbound_allowed": tier not in OUTBOUND_BLOCKED_TIERS,
    }


def outbound_verdict(posture: dict, route: dict) -> dict[str, object]:
    """May the launcher offer a clickable off-deck link right now?

    Fail-closed and single-authority: the page asks this, it does not decide
    it. Every refusal names the consequence and the remedy, because a greyed
    link with no sentence beside it is the silent degradation this project
    keeps paying for (docs/RESILIENCE.md rule 8).
    """
    if not posture.get("known"):
        return {"allowed": False, "state": "posture-unknown",
                "headline": "Threat posture unknown — off-deck links disabled",
                "detail": str(posture.get("reason") or "posture state unavailable"),
                "remedy": "systemctl status orionx-postured  "
                          "# then re-open this page"}
    if not posture.get("outbound_allowed"):
        return {"allowed": False, "state": "shields-up",
                "headline": "%s — off-deck links disabled" % posture["label"],
                "detail": "Decoys are live on a network you have declared "
                          "hostile. Opening a public OSINT site from here "
                          "announces this deck to that network, and to the "
                          "site. The links stay listed so you can copy them "
                          "to a machine that should be making the request.",
                "remedy": "Lower the posture in the Control Center "
                          "(Awareness -> Threat posture) if reaching out is "
                          "appropriate."}
    if not route.get("default_route"):
        return {"allowed": False, "state": "no-route",
                "headline": "No default route — off-deck links unreachable",
                "detail": "Nothing on this list that needs the internet will "
                          "load. Everything under LOCAL TOOLS still works: "
                          "this deck does its own analysis.",
                "remedy": "nmcli device status   # or: ip route"}
    return {"allowed": True, "state": "ok",
            "headline": "Link present via %s" % (route.get("interface") or "default route"),
            "detail": "A default route exists. That is not proof the internet "
                      "is reachable — only that this deck has somewhere to "
                      "send packets.",
            "remedy": ""}


def geoip_state(country_db: Path, asn_db: Path) -> dict[str, object]:
    """Presence of the optional geolocation databases, re-asked every request."""
    have_reader = True
    try:
        import maxminddb  # noqa: F401
    except ImportError:
        have_reader = False
    country = country_db.is_file()
    return {
        "available": bool(country and have_reader),
        "country_db": str(country_db),
        "country_db_present": country,
        "asn_db": str(asn_db),
        "asn_db_present": asn_db.is_file(),
        "reader_installed": have_reader,
        "reason": ("" if (country and have_reader) else
                   ("python3-maxminddb is not installed" if not have_reader
                    else "no country database at " + str(country_db))),
        "remedy": pewpew_feed.GEOIP_REMEDY,
        "license": "DB-IP Lite, CC BY 4.0 — see /opt/orionx/osint/GEOIP.txt",
    }


# ===========================================================================
# IMPURE: reading the deck
# ===========================================================================

def _read(path: Path, limit: int | None = None) -> str | None:
    try:
        if limit is None:
            return path.read_text(encoding="utf-8", errors="replace")
        with path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - limit))
            data = handle.read()
        if limit and len(data) == limit:
            data = data.split(b"\n", 1)[-1]      # drop the partial first line
        return data.decode("utf-8", errors="replace")
    except OSError:
        return None


def open_geoip():
    """Open the optional databases, or return (None, None). Never raises."""
    try:
        import maxminddb
    except ImportError:
        return None, None
    country = asn = None
    for path, slot in ((pewpew_feed.GEOIP_COUNTRY_DB, "country"),
                       (pewpew_feed.GEOIP_ASN_DB, "asn")):
        try:
            reader = maxminddb.open_database(path)
        except Exception:                                  # noqa: BLE001
            continue
        if slot == "country":
            country = _CountryShim(reader)
        else:
            asn = _AsnShim(reader)
    return country, asn


class _CountryShim:
    """Adapts maxminddb's raw .get() to the .country() locate() expects."""

    def __init__(self, reader):
        self._reader = reader

    def country(self, ip: str):
        return self._reader.get(ip)


class _AsnShim:
    def __init__(self, reader):
        self._reader = reader

    def asn(self, ip: str):
        return self._reader.get(ip)


def build_status() -> dict:
    route = read_default_route(_read(PROC_ROUTE) or "", _read(PROC_ROUTE6) or "")
    posture = read_posture(_read(POSTURE_STATUS))
    geo = geoip_state(Path(pewpew_feed.GEOIP_COUNTRY_DB),
                      Path(pewpew_feed.GEOIP_ASN_DB))
    bus_present = BUS.is_file()
    return {
        "schema": 1,
        "generated": time.time(),
        "decision": "DEC-PHASE12-043",
        "route": route,
        "posture": posture,
        "outbound": outbound_verdict(posture, route),
        "geoip": geo,
        "bus": {
            "path": str(BUS),
            "present": bus_present,
            "reason": "" if bus_present else (
                "the R.A.I.N. event bus does not exist yet. It is created by "
                "the first detector that publishes; on a quiet deck that is "
                "normal, and the map will stay empty until something happens."),
            "remedy": "" if bus_present else "systemctl status orionx-scanwatch orionx-postured",
        },
    }


def build_pewpew(window: float) -> dict:
    country, asn = open_geoip()
    text = _read(BUS, BUS_TAIL_BYTES)
    geo = geoip_state(Path(pewpew_feed.GEOIP_COUNTRY_DB),
                      Path(pewpew_feed.GEOIP_ASN_DB))
    if text is None:
        feed = pewpew_feed.build_feed([], window=window, geoip_state=geo)
        feed["bus_readable"] = False
        feed["bus_path"] = str(BUS)
        return feed
    feed = pewpew_feed.build_feed(text.splitlines(), window=window,
                                  reader=country, asn_reader=asn,
                                  geoip_state=geo)
    feed["bus_readable"] = True
    feed["bus_path"] = str(BUS)
    return feed


# ===========================================================================
# The server
# ===========================================================================

class Handler(http.server.SimpleHTTPRequestHandler):
    """Static files from the web root, plus two JSON endpoints."""

    server_version = "orionx-osint"
    sys_version = ""
    window = pewpew_feed.DEFAULT_WINDOW_SECONDS

    def log_message(self, fmt, *args):           # noqa: A003
        if os.environ.get("ORIONX_OSINT_VERBOSE"):
            sys.stderr.write("[orionx-osint] " + (fmt % args) + "\n")

    def _json(self, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _window(self) -> float:
        """Look-back from ?window=, clamped. An unbounded window would let a
        page ask this handler to parse the whole spool on every poll."""
        _, _, query = self.path.partition("?")
        for part in query.split("&"):
            key, _, value = part.partition("=")
            if key == "window":
                try:
                    return max(60.0, min(86400.0, float(value)))
                except ValueError:
                    break
        return self.window

    def do_GET(self):                            # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/api/status.json":
            self._json(build_status())
            return
        if path == "/api/pewpew.json":
            self._json(build_pewpew(self._window()))
            return
        super().do_GET()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def bind(root: Path, port: int, tries: int = PORT_TRIES):
    """Bind loopback, walking forward if the port is taken. Loopback only."""
    def factory(*args, **kwargs):
        return Handler(*args, directory=str(root), **kwargs)

    last = None
    for offset in range(max(1, tries)):
        try:
            return Server((HOST, port + offset), factory), port + offset
        except OSError as exc:
            last = exc
    raise SystemExit(
        "[orionx-osint] could not bind %s on ports %d-%d: %s\n"
        "               Another copy may already be running: try "
        "`ss -lntp | grep 87` and open the port it names."
        % (HOST, port, port + tries - 1, last))


# ===========================================================================
# Self-check — the Check stage of plan/do/check/repair
# ===========================================================================

def check_root(root: Path) -> list[tuple[str, bool, str, str]]:
    """(label, ok, detail, remedy) for every piece the surface claims to have.

    Build-time success is not runtime truth (rule 2), so this re-reads the
    filesystem rather than trusting that the hook ran. `orionx-osint --check`
    is what an operator runs when a page looks wrong, and what orionx-diag
    can call later.
    """
    rows: list[tuple[str, bool, str, str]] = []

    def row(label, ok, detail="", remedy=""):
        rows.append((label, bool(ok), detail, remedy))

    row("web root", root.is_dir(), str(root),
        "reinstall the ISO content: /opt/orionx/osint is staged from "
        "iso/config/includes.chroot")
    index = root / "index.html"
    row("launcher page", index.is_file(), str(index), "")

    catalogue = root / "links.json"
    if not catalogue.is_file():
        row("link catalogue", False, str(catalogue),
            "the launcher renders nothing without it")
    else:
        try:
            data = json.loads(catalogue.read_text(encoding="utf-8"))
            row("link catalogue", True,
                "%d local, %d installable, %d online"
                % (len(data.get("local") or []),
                   len(data.get("installable") or []),
                   len(data.get("online") or [])), "")
        except (OSError, ValueError) as exc:
            row("link catalogue", False, "unparseable: %s" % exc,
                "fix or restore /opt/orionx/osint/links.json")

    chef = root / "cyberchef" / "index.html"
    row("CyberChef", chef.is_file(), str(chef),
        "the launcher's CyberChef entry will 404")
    manifest = root / "cyberchef" / "MANIFEST.sha256"
    row("CyberChef manifest", manifest.is_file(), str(manifest),
        "cannot verify the vendored build without it")

    recipes = root / "recipes.json"
    if recipes.is_file():
        try:
            n = len(json.loads(recipes.read_text(encoding="utf-8")).get("recipes") or [])
            row("CyberChef IR recipes", n > 0, "%d recipes" % n, "")
        except (OSError, ValueError) as exc:
            row("CyberChef IR recipes", False, "unparseable: %s" % exc, "")
    else:
        row("CyberChef IR recipes", False, str(recipes), "")

    row("pew-pew map", (root / "pewpew" / "index.html").is_file(),
        str(root / "pewpew" / "index.html"), "")

    status = build_status()
    row("event bus", status["bus"]["present"], status["bus"]["path"],
        status["bus"]["remedy"])
    row("threat posture", status["posture"]["known"],
        str(status["posture"]["label"]), str(status["posture"]["reason"]))
    row("GeoIP (optional)", status["geoip"]["available"],
        status["geoip"]["reason"] or str(status["geoip"]["country_db"]),
        "" if status["geoip"]["available"] else status["geoip"]["remedy"])
    return rows


def run_check(root: Path) -> int:
    rows = check_root(root)
    width = max(len(r[0]) for r in rows)
    # Only the pieces that are supposed to be on every deck can fail the
    # exit code. GeoIP and the bus are legitimately absent on a healthy deck,
    # so they report but do not fail — a check that cries wolf gets ignored.
    optional = {"GeoIP (optional)", "event bus", "threat posture"}
    bad = 0
    print("orionx-osint self-check  (DEC-PHASE12-043)")
    print("-" * (width + 46))
    for label, ok, detail, remedy in rows:
        mark = " ok " if ok else ("note" if label in optional else "MISS")
        if not ok and label not in optional:
            bad += 1
        print("[%s] %-*s  %s" % (mark, width, label, detail))
        if not ok and remedy:
            print("       %-*s  -> %s" % (width, "", remedy))
    print("-" * (width + 46))
    if bad:
        print("%d required component(s) missing. The launcher will show gaps, "
              "not pretend." % bad)
    else:
        print("All required components present.")
    return 1 if bad else 0


# ===========================================================================
# Entry point
# ===========================================================================

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="orionx-osint",
        description="Serve the Orion-X OSINT launcher, CyberChef and the "
                    "pew-pew attack map on 127.0.0.1.")
    parser.add_argument("--root", default=str(DEFAULT_ROOT),
                        help="web root (default: %(default)s)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help="loopback port, walks forward if busy "
                             "(default: %(default)s)")
    parser.add_argument("--page", default="",
                        choices=("", "cyberchef", "pewpew"),
                        help="open this page instead of the launcher")
    parser.add_argument("--window", type=float,
                        default=pewpew_feed.DEFAULT_WINDOW_SECONDS,
                        help="map look-back in seconds (default: %(default)s)")
    parser.add_argument("--no-browser", action="store_true",
                        help="serve without launching a browser")
    parser.add_argument("--check", action="store_true",
                        help="report what is present and exit")
    parser.add_argument("--once", action="store_true",
                        help="handle a single request then exit (tests)")
    args = parser.parse_args(argv)

    root = Path(args.root)
    if args.check:
        return run_check(root)

    if not (root / "index.html").is_file():
        sys.stderr.write(
            "[orionx-osint] no launcher page at %s\n"
            "               The OSINT surface is not installed on this deck. "
            "Nothing else here will work.\n"
            "               Run `orionx-osint --check` for the full list.\n"
            % (root / "index.html"))
        return 1

    Handler.window = args.window
    httpd, port = bind(root, args.port)
    url = "http://%s:%d/%s" % (HOST, port,
                               {"cyberchef": "cyberchef/",
                                "pewpew": "pewpew/"}.get(args.page, ""))
    # flush=True throughout: stdout is block-buffered when this is piped to a
    # log, and a server whose "I am up" line only appears after it exits is a
    # server nobody can tell has started.
    print("[orionx-osint] serving %s at %s" % (root, url), flush=True)
    print("[orionx-osint] loopback only — nothing on the network can reach this.",
          flush=True)
    for label, ok, detail, remedy in check_root(root):
        if not ok:
            print("[orionx-osint] DEGRADED: %s — %s%s"
                  % (label, detail, ("  -> " + remedy) if remedy else ""), flush=True)
    print("[orionx-osint] Ctrl-C to stop.", flush=True)

    if args.once:
        # ThreadingMixIn hands the request to a thread and returns, so a plain
        # handle_request() + server_close() races the handler and the client
        # sees a closed connection. Tell the mixin to join on close.
        httpd.daemon_threads = False
        httpd.block_on_close = True
        httpd.handle_request()
        httpd.server_close()
        return 0

    if not args.no_browser:
        threading.Thread(target=_open_browser, args=(url,), daemon=True).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[orionx-osint] stopped.")
    finally:
        httpd.server_close()
    return 0


def _open_browser(url: str) -> None:
    time.sleep(0.3)
    # xdg-open first: it honours the desktop's default browser, which on this
    # deck is firefox-esr. webbrowser is the fallback for a bare console.
    try:
        if subprocess.call(["xdg-open", url],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL) == 0:
            return
    except OSError:
        pass
    try:
        webbrowser.open(url)
    except Exception:                                      # noqa: BLE001
        print("[orionx-osint] could not open a browser; go to %s yourself." % url)


if __name__ == "__main__":
    sys.exit(main())
