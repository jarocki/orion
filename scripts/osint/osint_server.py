#!/usr/bin/env python3
"""osint_server — the Orion Workbench (analyst toolbox), served on loopback.

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

@decision DEC-PHASE12-045
@title GODSEYE on Orion-X: vendored static globe, posture-gated at the server
@status accepted
@rationale GODSEYE (VrushankPatel/godseye, Apache-2.0) is a CesiumJS globe
  whose every layer is a live third-party API. It is vendored here as a
  pre-built static bundle under /opt/orionx/osint/godseye/app and served by
  THIS server, because standing up a second loopback server would mean a
  second answer to "may this deck reach out right now" — and that question
  already has exactly one authority here: outbound_verdict().

  The gate is enforced where the bytes are handed over, not only in the
  page's JavaScript. A browser-side check is a courtesy; a server that
  refuses to serve the document is a control. At a blocked posture, or with
  no default route, a request for the globe returns 503 and a page that says
  what is not working, what the consequence is, what still works, and the
  command that changes it (docs/RESILIENCE.md rule 8).

  The five /api/ routes upstream serves from its Node backend answer 501
  with a named reason rather than a bare 404, because a 404 renders in
  GODSEYE as an empty layer, and an empty layer on this deck reads as
  "nothing is there" — which is a lie. Orion-X runs no Node at runtime.
"""

from __future__ import annotations

import argparse
import http.client
import http.server
import json
import signal
import os
import socketserver
import shutil
import subprocess
import sys
import threading
import time
import webbrowser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pewpew_feed  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "awareness"))
import deck_vitals  # noqa: E402  (DEC-PHASE12-049: same hostname/IP/vitals as the Cockpit)

# --- Where things are -------------------------------------------------------
DEFAULT_ROOT = Path(os.environ.get("ORIONX_OSINT_ROOT", "/opt/orionx/osint"))
WEB_ROOT = DEFAULT_ROOT        # set from --root in main(); build_status() reads links.json here
BUS = Path(os.environ.get("ORIONX_EVENT_LOG", pewpew_feed.EVENT_LOG))
POSTURE_STATUS = Path(os.environ.get("ORIONX_POSTURE_STATUS",
                                     "/run/orionx/posture-status.json"))
PROC_ROUTE = Path(os.environ.get("ORIONX_PROC_ROUTE", "/proc/net/route"))
PROC_ROUTE6 = Path(os.environ.get("ORIONX_PROC_ROUTE6", "/proc/net/ipv6_route"))

HOST = "127.0.0.1"
DEFAULT_PORT = 8787
PORT_TRIES = 8

# UX-06: the remedy names the surface that exists on this image.
POSTURE_REMEDY = ("Lower the posture in Orion Cockpit -> Awareness -> Threat "
                  "posture (or: orionx-cockpit --tab awareness) if reaching "
                  "out is appropriate.")

# @decision DEC-PHASE12-086
# @title The Workbench answers only requests addressed to loopback by name
# @status accepted
# @rationale QA round 1 (security F3). Binding 127.0.0.1 does not stop DNS
#   rebinding: a page the operator opens while researching an adversary can
#   rebind its own name to 127.0.0.1 and read /api/pewpew.json (what the IDS
#   sees, the deck's addresses, its posture). Every request must carry a Host
#   of 127.0.0.1, localhost or [::1] (with this server's port), and any Origin
#   it carries must be one of those same origins; Sec-Fetch-Site cross-site is
#   refused. Anything else gets 403 and a sentence saying why. Same allowlist
#   idea as Pivotglass (pivotglass/web/server.py _host_allowed). Every
#   response also carries X-Content-Type-Options: nosniff.
LOOPBACK_NAMES = ("127.0.0.1", "localhost", "[::1]")


def request_allowed(host: str | None, origin: str | None, fetch_site: str | None,
                    port: int) -> tuple[bool, str]:
    """Pure: may a request with these headers be answered? (ok, why-not)."""
    allowed = {"%s:%d" % (name, port) for name in LOOPBACK_NAMES}
    h = (host or "").strip().lower()
    if h not in allowed:
        return False, "Host %r is not this deck's loopback address" % (host or "")
    if (fetch_site or "").strip().lower() == "cross-site":
        return False, "cross-site request"
    o = (origin or "").strip().lower()
    if o and o != "null" and o not in {"http://" + a for a in allowed}:
        return False, "Origin %r is not this Workbench" % origin
    if o == "null":
        return False, "opaque (null) Origin"
    return True, ""

# Tier 2 is Deception: decoys are live on a network the operator has declared
# hostile. Reaching out to a public OSINT site from that network announces
# this deck to it. The launcher honours this; it is declared here, once.
OUTBOUND_BLOCKED_TIERS = ("2",)

# Bus reads are bounded. The spool is tmpfs and normally small, but a flood
# must not make this handler allocate the whole thing.
BUS_TAIL_BYTES = 2 * 1024 * 1024

# --- GODSEYE (DEC-PHASE12-045) ---------------------------------------------
# The vendored bundle lives under the OSINT web root, so it inherits this
# server's loopback binding and this server's posture authority.
GODSEYE_APP_PREFIX = "/godseye/app"

# Upstream GODSEYE proxies these through a Node service. Orion-X runs no Node
# at runtime, so they do not exist here. They answer 501 and name themselves;
# the alternative is a 404 the application draws as an empty layer.
GODSEYE_BACKEND_ROUTES = (
    ("/api/flights", "Aircraft via the upstream backend proxy"),
    ("/api/cctv/", "CCTV source index and frame grabs"),
    ("/api/radio/", "Radio station list and click-through"),
    ("/api/traffic/", "Traffic flow tiles and status"),
    ("/api/overpass", "OpenStreetMap Overpass queries"),
)


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
                "remedy": POSTURE_REMEDY}
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


def godseye_backend_route(path: str) -> str | None:
    """Name the upstream Node route this request is asking for, or None.

    Pure. The point of naming it is that the refusal can name it too: an
    operator who sees "Aircraft via the upstream backend proxy — not served"
    knows which layer went quiet and why, which a 404 never tells them.
    """
    for prefix, label in GODSEYE_BACKEND_ROUTES:
        if path == prefix.rstrip("/") or path.startswith(prefix):
            return label
    return None


def godseye_gated(path: str) -> bool:
    """Is `path` one of the GODSEYE entry documents the posture gate governs?
    Pure. The handler asks this FIRST, so a static asset never pays for the
    posture/route reads (python P2-2: build_status, with a 0.15 s vitals
    sample and subprocesses, used to run for every file served)."""
    if not (path == GODSEYE_APP_PREFIX or path.startswith(GODSEYE_APP_PREFIX + "/")):
        return False
    return path.endswith("/") or path.endswith(".html") or path == GODSEYE_APP_PREFIX


def godseye_gate(path: str, outbound: dict) -> dict[str, object] | None:
    """May this request for the GODSEYE document be served? None = yes.

    Pure, and deliberately the ONLY place the question is answered for this
    bundle. It governs the entry documents, not every asset: without
    index.html the application never boots, and gating 400 static chunks
    would mean re-reading /proc and the posture file four hundred times to
    reach the same conclusion.

    GODSEYE has no offline mode. Its base imagery, its terrain and every one
    of its layers is a live third-party request. Served with no route it
    draws a featureless dark ellipsoid; served at a raised posture it
    announces this deck to several dozen hosts. Both are refusals here, and
    each says which.
    """
    if not godseye_gated(path):
        return None
    if outbound.get("allowed"):
        return None

    state = str(outbound.get("state") or "blocked")
    if state == "no-route":
        return {
            "state": state,
            "headline": "No default route — GODSEYE has nothing to draw",
            "what": "Every layer in GODSEYE is a live internet API, and so is "
                    "the map underneath them. With no route the globe would "
                    "render as a featureless dark sphere with no imagery, no "
                    "aircraft, no satellites and no seismic events.",
            "so_what": "That empty globe is indistinguishable from a quiet "
                       "world. It is not evidence that nothing is happening; "
                       "it is evidence that this deck asked nobody.",
            "still_works": "Everything under ON THIS DECK in the investigation "
                           "surface: CyberChef, the artifact tools, the "
                           "R.A.I.N. attack map of what THIS deck has seen.",
            "remedy": str(outbound.get("remedy") or "nmcli device status   # or: ip route"),
        }
    if state == "shields-up":
        return {
            "state": state,
            "headline": str(outbound.get("headline")
                            or "Raised posture — GODSEYE will not be served"),
            "what": "GODSEYE cannot be opened without contacting dozens of "
                    "third-party hosts, and roughly fifteen of its feeds go "
                    "through anonymous public relays (api.allorigins.win, "
                    "r.jina.ai) that see this deck's address and the exact "
                    "question being asked.",
            "so_what": "On a network you have declared hostile, that is an "
                       "announcement of this deck and of what it is looking "
                       "for. Decoys are live; this would undo them.",
            "still_works": "The whole local Workbench. The host "
                           "list is readable offline at "
                           "/opt/orionx/osint/godseye/HOSTS.txt.",
            "remedy": str(outbound.get("remedy") or POSTURE_REMEDY),
        }
    return {
        "state": state,
        "headline": str(outbound.get("headline")
                        or "Deck status unknown — GODSEYE will not be served"),
        "what": "This server could not establish what threat posture the deck "
                "is in. " + str(outbound.get("detail") or ""),
        "so_what": "Serving a page that reaches out to dozens of third "
                   "parties on an unknown posture is a decision this deck is "
                   "not entitled to make on your behalf. It fails closed.",
        "still_works": "The whole local Workbench.",
        "remedy": str(outbound.get("remedy")
                      or "systemctl status orionx-postured"),
    }


def godseye_refusal_html(refusal: dict) -> str:
    """The refusal page itself. Pure, self-contained, no external resource."""
    def esc(value: object) -> str:
        return (str(value).replace("&", "&amp;").replace("<", "&lt;")
                .replace(">", "&gt;"))
    return (
        "<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        "<title>GODSEYE not served</title><style>"
        "body{background:#0b0d11;color:#e6e8ec;font-family:system-ui,sans-serif;"
        "margin:0;padding:48px 20px;line-height:1.55}"
        "main{max-width:760px;margin:0 auto}"
        "h1{font-size:1.25rem;letter-spacing:.04em;color:#ff5f56;margin:0 0 4px}"
        "p.state{font-family:ui-monospace,monospace;font-size:.78rem;"
        "color:#6b7280;letter-spacing:.14em;text-transform:uppercase;margin:0 0 20px}"
        "h2{font-size:.78rem;letter-spacing:.18em;text-transform:uppercase;"
        "color:#ff6a13;margin:22px 0 4px}"
        "p{margin:0;color:#9aa0a6}"
        "code{display:block;margin-top:8px;background:#0a0c10;border:1px solid #242a35;"
        "border-radius:6px;padding:10px 12px;color:#ffb15c;font-size:.84rem;"
        "white-space:pre-wrap;overflow-x:auto}"
        "a{color:#7ab8ff}</style></head><body><main>"
        "<h1>" + esc(refusal.get("headline")) + "</h1>"
        "<p class=\"state\">GODSEYE &middot; refused by orionx-osint &middot; "
        + esc(refusal.get("state")) + "</p>"
        "<h2>What is not working</h2><p>" + esc(refusal.get("what")) + "</p>"
        "<h2>Why that matters</h2><p>" + esc(refusal.get("so_what")) + "</p>"
        "<h2>What still works</h2><p>" + esc(refusal.get("still_works")) + "</p>"
        "<h2>Remedy</h2><code>" + esc(refusal.get("remedy")) + "</code>"
        "<h2>Before you open it</h2><p>Read "
        "<a href=\"/godseye/HOSTS.txt\">/opt/orionx/osint/godseye/HOSTS.txt</a> "
        "&mdash; every host this bundle can contact, generated from the bytes "
        "that ship.</p>"
        "<p style=\"margin-top:26px\"><a href=\"/godseye/\">&larr; back to the "
        "GODSEYE preflight</a> &middot; <a href=\"/\">Workbench</a></p>"
        "</main></body></html>\n")


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


#: Why each optional GeoIP database failed to open on the last attempt
#: (path -> error). Surfaced in the pew-pew feed so "no geolocation" says why.
GEOIP_OPEN_ERRORS: dict[str, str] = {}


def open_geoip():
    """Open the optional databases, or return (None, None). Never raises."""
    try:
        import maxminddb
    except ImportError:
        return None, None
    country = asn = None
    GEOIP_OPEN_ERRORS.clear()
    for path, slot in ((pewpew_feed.GEOIP_COUNTRY_DB, "country"),
                       (pewpew_feed.GEOIP_ASN_DB, "asn")):
        if not Path(path).is_file():
            continue
        try:
            reader = maxminddb.open_database(path)
        except Exception as exc:                           # noqa: BLE001 - any reader fault
            GEOIP_OPEN_ERRORS[str(path)] = repr(exc)[:200]
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


def load_installable(root: Path) -> list[dict]:
    """links.json's installable entries, or [] on any failure. Never raises."""
    try:
        data = json.loads((Path(root) / "links.json").read_text(encoding="utf-8"))
        items = data.get("installable", [])
        return [i for i in items if isinstance(i, dict) and i.get("id")]
    except (OSError, ValueError, AttributeError):
        return []


def optional_state(entries: list[dict], geoip_available: bool,
                   exists=os.path.exists, find_spec=None) -> dict:
    """Which optional installers have actually been run on THIS deck. Pure.

    Each entry's `probe` is a list of paths (or `python:<module>`) that exist
    only after its installer succeeded — the same gates the installers use
    for idempotence. An entry with no probe is answered by what the server
    already knows (GeoIP), or reported unknown rather than guessed. The page
    shows 'installed' only from evidence (docs/RESILIENCE.md rule 3).
    """
    if find_spec is None:
        import importlib.util  # noqa: PLC0415
        find_spec = importlib.util.find_spec
    out: dict = {}
    for it in entries:
        iid = str(it.get("id"))
        probe = it.get("probe") or []
        if iid == "geoip" and not probe:
            out[iid] = {"installed": bool(geoip_available), "known": True,
                        "evidence": "GeoIP databases readable" if geoip_available else "databases absent"}
            continue
        if not probe:
            out[iid] = {"installed": False, "known": False, "evidence": "no probe declared"}
            continue
        hit = None
        for p in probe:
            p = str(p)
            if p.startswith("python:"):
                try:
                    if find_spec(p[7:]) is not None:
                        hit = p
                except (ImportError, ValueError):
                    pass
            elif exists(p):
                hit = p
            if hit:
                break
        out[iid] = {"installed": hit is not None, "known": True,
                    "evidence": hit or ("none of: " + ", ".join(map(str, probe)))}
    return out


def current_outbound() -> dict:
    """outbound_verdict from the two local reads only (no vitals, no GeoIP):
    what the GODSEYE gate needs, and nothing it does not."""
    route = read_default_route(_read(PROC_ROUTE) or "", _read(PROC_ROUTE6) or "")
    return outbound_verdict(read_posture(_read(POSTURE_STATUS)), route)


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
        "deck": deck_vitals.collect(sample=0.15),
        "geoip": geo,
        "server": {"pid": os.getpid(), "root": str(WEB_ROOT)},
        # DEC-PHASE12-052: optional installers, with evidence of whether each
        # has been run on this deck, so the Workbench can say so.
        "optional": optional_state(load_installable(WEB_ROOT), bool(geo.get("available"))),
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
    if GEOIP_OPEN_ERRORS:
        geo = dict(geo, open_errors=dict(GEOIP_OPEN_ERRORS))
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

    def end_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        super().end_headers()

    def _refuse_foreign(self) -> bool:
        """DEC-PHASE12-086: 403 anything not addressed to loopback by name."""
        ok, why = request_allowed(self.headers.get("Host"), self.headers.get("Origin"),
                                  self.headers.get("Sec-Fetch-Site"),
                                  self.server.server_address[1])
        if ok:
            return False
        body = ("403 refused: %s. The Orion Workbench answers only "
                "http://127.0.0.1:%d/ (or localhost) opened on this deck; a "
                "page that rebinds another name to this address cannot read "
                "it.\n" % (why, self.server.server_address[1])).encode("utf-8")
        self.send_response(403)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        return True

    def do_HEAD(self):                           # noqa: N802
        if self._refuse_foreign():
            return
        super().do_HEAD()

    def _json(self, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json_status(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _html_status(self, code: int, html: str) -> None:
        body = html.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
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
        if self._refuse_foreign():
            return
        path = self.path.split("?", 1)[0]
        if path == "/api/status.json":
            self._json(build_status())
            return
        if path == "/api/pewpew.json":
            self._json(build_pewpew(self._window()))
            return

        # GODSEYE's Node backend does not exist on this deck (DEC-PHASE12-045).
        label = godseye_backend_route(path)
        if label is not None:
            self._json_status(501, {
                "error": "no-node-backend",
                "route": path,
                "layer": label,
                "detail": "Orion-X runs no Node at runtime, so the upstream "
                          "GODSEYE backend that proxies this route is not "
                          "installed. This layer cannot work on this deck, "
                          "with or without a network.",
                "remedy": "See section F of /opt/orionx/osint/godseye/HOSTS.txt",
            })
            return

        refusal = godseye_gate(path, current_outbound()) if godseye_gated(path) else None
        if refusal is not None:
            self._html_status(503, godseye_refusal_html(refusal))
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
# One server per operator (UX-25)
# ===========================================================================
# @decision DEC-PHASE12-087
# @title One Workbench server per operator, discoverable, reused, stoppable
# @status accepted
# @rationale QA round 1 (UX-25). Every menu launch and every Cockpit "Run"
#   bound a NEW server on the next port (8787..8794); the ninth died silently
#   and nothing said how many were running or how to stop them. Now a running
#   server records "port pid" in $XDG_RUNTIME_DIR/orionx-osint.port; a launch
#   first asks that port whether it is really this server (GET
#   /api/status.json, pid must match) and, if so, just opens the page there.
#   `orionx-osint --status` says what is serving; `--stop` stops it. A stale
#   file (server gone) is ignored and replaced.

def state_file() -> Path:
    base = os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
    if not Path(base).is_dir():
        base = str(Path.home() / ".cache")
    return Path(base) / "orionx-osint.port"


def probe_server(port: int, timeout: float = 1.0) -> dict | None:
    """The status a Workbench on this loopback port reports, or None."""
    try:
        conn = http.client.HTTPConnection(HOST, port, timeout=timeout)
        conn.request("GET", "/api/status.json", headers={"Host": "%s:%d" % (HOST, port)})
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        if resp.status != 200:
            return None
        obj = json.loads(data.decode("utf-8"))
        return obj if isinstance(obj, dict) and obj.get("decision") == "DEC-PHASE12-043" else None
    except (OSError, ValueError, http.client.HTTPException):
        return None


def running_server(path: Path | None = None) -> dict | None:
    """{"port", "pid", "root"} of the live recorded server, else None."""
    path = path or state_file()
    try:
        port_s, pid_s = path.read_text(encoding="utf-8").split()[:2]
        port, pid = int(port_s), int(pid_s)
    except (OSError, ValueError):
        return None
    status = probe_server(port)
    server = (status or {}).get("server") or {}
    if status is None or server.get("pid") != pid:
        return None
    return {"port": port, "pid": pid, "root": server.get("root", "")}


def record_server(port: int, path: Path | None = None) -> Path | None:
    path = path or state_file()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + ".%d.tmp" % os.getpid())
        tmp.write_text("%d %d\n" % (port, os.getpid()), encoding="utf-8")
        os.replace(tmp, path)
        return path
    except OSError as exc:
        print("[orionx-osint] cannot record %s (%s); a second launch will start "
              "a second server" % (path, exc), flush=True)
        return None


def forget_server(path: Path | None) -> None:
    if path is None:
        return
    try:
        if path.read_text(encoding="utf-8").split()[1] == str(os.getpid()):
            path.unlink()
    except (OSError, IndexError):
        pass


def page_url(port: int, page: str) -> str:
    return "http://%s:%d/%s" % (HOST, port, {"cyberchef": "cyberchef/",
                                             "pewpew": "pewpew/",
                                             "godseye": "godseye/"}.get(page, ""))


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

    # GODSEYE (DEC-PHASE12-045). Required: if the menu offers it, it ships.
    gs = root / "godseye"
    row("GODSEYE preflight", (gs / "index.html").is_file(),
        str(gs / "index.html"),
        "the menu entry would open nothing")
    row("GODSEYE bundle", (gs / "app" / "index.html").is_file(),
        str(gs / "app" / "index.html"),
        "re-vendor per /opt/orionx/osint/godseye/PROVENANCE.txt")
    row("GODSEYE host list", (gs / "HOSTS.txt").is_file(), str(gs / "HOSTS.txt"),
        "an operator cannot see what the globe would contact")
    row("GODSEYE manifest", (gs / "MANIFEST.sha256").is_file(),
        str(gs / "MANIFEST.sha256"),
        "cannot verify the vendored bundle without it")

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
                        choices=("", "cyberchef", "pewpew", "godseye"),
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
    parser.add_argument("--status", action="store_true",
                        help="say whether a Workbench server is running, and where")
    parser.add_argument("--stop", action="store_true",
                        help="stop the running Workbench server")
    parser.add_argument("--json", action="store_true",
                        help="with --status: one JSON object (for the Cockpit)")
    parser.add_argument("--new", action="store_true",
                        help="start another server even if one is running")
    args = parser.parse_args(argv)

    root = Path(args.root)
    global WEB_ROOT
    WEB_ROOT = root
    if args.check:
        return run_check(root)

    if args.status or args.stop:
        live = running_server()
        if args.status:
            if args.json:
                print(json.dumps({"running": live is not None, **(live or {}),
                                  "url": page_url(live["port"], "") if live else None,
                                  "state_file": str(state_file())}))
            elif live:
                print("Workbench: serving on :%d (pid %d) — %s   stop: orionx-osint --stop"
                      % (live["port"], live["pid"], page_url(live["port"], "")))
            else:
                print("Workbench: not running   start: orionx-osint")
            return 0 if live else 3
        if live is None:
            print("Workbench: not running; nothing to stop")
            return 0
        try:
            os.kill(live["pid"], signal.SIGTERM)
        except OSError as exc:
            print("Workbench: cannot stop pid %d: %s" % (live["pid"], exc))
            return 1
        for _ in range(20):
            if probe_server(live["port"], timeout=0.25) is None:
                print("Workbench: stopped (was :%d, pid %d)" % (live["port"], live["pid"]))
                return 0
            time.sleep(0.1)
        print("Workbench: pid %d did not stop within 2 s" % live["pid"])
        return 1

    if not args.once and not args.new:
        live = running_server()
        if live is not None:
            url = page_url(live["port"], args.page)
            print("[orionx-osint] already serving on :%d (pid %d); opening %s"
                  % (live["port"], live["pid"], url), flush=True)
            print("[orionx-osint] stop it with: orionx-osint --stop", flush=True)
            if not args.no_browser:
                _open_browser(url)
            return 0

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
    url = page_url(port, args.page)
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

    recorded = record_server(port)
    signal.signal(signal.SIGTERM, _sigterm)     # --stop: clean exit, state file removed
    if not args.no_browser:
        threading.Thread(target=_open_browser, args=(url,), daemon=True).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[orionx-osint] stopped.", flush=True)
    finally:
        httpd.server_close()
        forget_server(recorded)
    return 0


def _sigterm(_signum, _frame):
    raise KeyboardInterrupt


def browser_argv(url: str, which=shutil.which, runtime_dir: str | None = None) -> list[str]:
    """How to open the Workbench. Pure.

    @decision DEC-PHASE12-067
    @title The Workbench opens in its own Firefox profile, never the OSINT one
    @status accepted
    @rationale Security F16/F3: the Workbench serves this deck's own alert
      stream to the browser; opening it in the same profile the operator uses
      to look at adversary pages gave a hostile page a same-browser path to
      it (DNS rebinding was one). A dedicated profile under XDG_RUNTIME_DIR
      (tmpfs on the deck, gone at reboot) keeps the two worlds apart without
      touching the operator's browsing profile. xdg-open stays as the
      fallback when firefox-esr is not installed.
    """
    ff = which("firefox-esr") or which("firefox")
    if ff:
        base = runtime_dir or os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/orionx-{os.getuid()}"
        return [ff, "--no-remote", "--profile", os.path.join(base, "orionx-workbench"), url]
    return ["xdg-open", url]


def _open_browser(url: str) -> None:
    time.sleep(0.3)
    argv = browser_argv(url)
    try:
        if argv[0] != "xdg-open":
            os.makedirs(os.path.dirname(argv[3]), exist_ok=True)
            os.makedirs(argv[3], mode=0o700, exist_ok=True)
            subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
            return
        if subprocess.call(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0:
            return
    except OSError:
        pass
    try:
        webbrowser.open(url)
    except Exception:                                      # noqa: BLE001
        print("[orionx-osint] could not open a browser; go to %s yourself." % url)


if __name__ == "__main__":
    sys.exit(main())
