"""suricata_capture — make Suricata capture something, and prove that it did.

@decision DEC-PHASE12-038
@title Suricata gets an Orion-X capture config and an interface heartbeat,
  driven by the existing posture authority
@status accepted
@rationale On the operator's deck at Tier 1, repeatedly:

    suricata.service: Main process exited, code=exited, status=1/FAILURE
    suricata.service: Scheduled restart job, restart counter is at 1..5
    suricata.service: Start request repeated too quickly.

  DEC-PHASE12-034 bounded that loop. It deliberately did not fix the cause.
  This is the cause, reproduced in a debian:trixie-slim container running the
  ISO's own suricata 7.0.10 rather than inferred:

    Error: af-packet: eth0: failed to find interface: No such device
    Error: af-packet: eth0: failed to init socket for interface
    Error: threads: thread "W#01-eth0" failed to start: flags 0423

  Debian's unit hardcodes `-c /etc/suricata/suricata.yaml` and Debian's
  suricata.yaml hardcodes `af-packet: - interface: eth0`. The image shipped
  neither an /etc/default/suricata nor a suricata.yaml of its own, so a deck
  whose NIC is enp2s0, wlan0 or a USB adapter had an IDS that could not open
  a socket. It is not a timing problem and no amount of restarting fixes it.

  So: the interface list is DATA, measured from the only dependency-free
  source of truth the kernel offers — /sys/class/net/<if>/statistics/
  rx_packets — and written into a generated af-packet include that Orion-X's
  own config pulls in. The five stages, applied to capture:

    Plan   — selected_interfaces() is pure: samples in, interface list out.
    Do     — write_interfaces_yaml() + start/restart, in that order, because
             the config must exist before the engine reads it.
    Check  — verify_capture() asks the RUNNING engine over its unix socket
             which interfaces it attached to and how many packets each has
             taken. `systemctl start` returning 0 proves only that systemd
             forked something.
    Repair — the caller's bounded attempt budget (DEC-PHASE12-034), reset
             when the interface set changes because that is a new situation.
    Loop   — the heartbeat never stops; a USB NIC plugged in mid-incident is
             picked up, and one that is yanked is dropped before it can take
             the engine down with it.

  Why a module and not a daemon: orionx-postured is the single posture
  authority (DEC-PHASE12-024/028/034). A second daemon would need its own
  copy of the tier to decide whether to capture at all, and two things
  holding a tier is two things that drift. This is a library the posture
  daemon drives, in the same shape as rain_lib and healing_lib.

  WHY A RATE AND NOT A COUNTER. rx_packets is a lifetime counter. An
  interface that carried traffic at boot and has been dead for an hour still
  reads in the millions, so "non-zero" marks a dead NIC live forever. Every
  judgement here is a DELTA inside a sliding window.

  THE THRESHOLD, and why this one. An interface counts as live at
  >= LIVE_MIN_PACKETS packets inside LIVE_WINDOW seconds: 5 packets / 30 s,
  about 0.17 pkt/s. The floor is set by what a disconnected or down NIC
  produces, which is exactly zero. The ceiling is set by the quietest thing
  an operator would still want watched: a point-to-point cable to a single
  target with no broadcast domain, which can sit well under 1 pkt/s between
  probes. Any attached Ethernet or Wi-Fi segment carries far more than this
  in ARP, mDNS, IPv6 RA, DHCP and STP alone. A rate expressed per second
  rather than per window also means the answer does not change when the
  sampling cadence does. An operator who needs a silent SPAN port watched
  anyway pins it with --capture-iface, which bypasses the test entirely.

  ANTI-THRASH. Reconfiguring Suricata means restarting it, and a restart is
  a gap in coverage. Three independent brakes, because a flapping link must
  not cost a restart every few seconds:

    1. Hysteresis. Promotion is fast (an interface joins as soon as it is
       measurably live, so a mid-incident NIC is watched within seconds).
       Demotion is slow: an interface must be quiet for QUIET_DEMOTE_SECONDS
       (5 min) before it is dropped. A link that flaps on a 30 s cycle never
       leaves the set, so it never triggers a reconfigure.
    2. A global cooldown. RECONFIG_COOLDOWN (2 min) between applications, no
       matter what changed. This bounds restarts to at most one per two
       minutes even in a pathological environment.
    3. Idempotence. The desired set is compared against the set actually
       written, and the file is compared byte-for-byte before writing. No
       difference, no write, no restart. The rendered file therefore carries
       no timestamp: a timestamp would make every render differ from the
       last and defeat the comparison.

  A VANISHED INTERFACE IS THE EXCEPTION. Hysteresis protects an interface
  that goes quiet. An interface that disappears from /sys is dropped at once
  and without cooldown, because measured in the container, ONE unopenable
  device fails the whole engine, not just its own thread:

    Error: af-packet: dummy0: failed to find interface: No such device
    Error: threads: thread "W#01-eth0" failed to start in time

  Keeping a yanked USB NIC in the config to avoid a restart would therefore
  cost all capture on every interface at the next start.

  CLUSTER IDS MUST DIFFER PER INTERFACE. Measured, not read: two af-packet
  entries sharing cluster-id 98 produce

    Error: af-packet: dummy0: failed to set fanout mode: Invalid argument

  and the engine dies. With distinct ids the same pair reports
  "Engine started." The generator allocates one id per interface.
"""
from __future__ import annotations

import json
import os
import subprocess
from collections import deque
from pathlib import Path

# --- Paths (single authorities, all overridable for tests) ------------------

SYSFS_NET = Path("/sys/class/net")

# Orion-X's top-level Suricata config, which includes Debian's and then the
# generated interface list. Shipped in includes.chroot; see its own header.
ORIONX_YAML = Path("/etc/suricata/orionx.yaml")

# The generated af-packet include. It lives under /var/lib/suricata, not
# /etc/suricata, for a load-bearing reason: orionx-postured.service runs with
# ProtectSystem=strict and ReadWritePaths=/run/orionx /var/lib/suricata
# /var/lib/orionx, so /etc is read-only to the one process that must rewrite
# this file. /var/lib/suricata is already writable for the DEC-PHASE11-008
# gate file, and this is Suricata's own state directory.
INTERFACES_YAML = Path("/var/lib/suricata/orionx-interfaces.yaml")

# Suricata's unix command socket, relocated by orionx.yaml for the same
# ProtectSystem=strict reason: connect() needs write access to the socket
# inode, and /run is read-only inside the daemon's namespace. The stock path
# is still tried, so verification keeps working if the drop-in is ever absent.
COMMAND_SOCKET = Path("/var/lib/suricata/orionx-command.socket")
STOCK_COMMAND_SOCKET = Path("/var/run/suricata-command.socket")

SURICATA_BIN = "suricata"
SURICATASC_BIN = "suricatasc"

# --- Thresholds (justified in the module docstring) -------------------------

HEARTBEAT_SECONDS = 5.0        # how often interfaces are sampled
LIVE_WINDOW = 30.0             # the interval a packet delta is measured over
LIVE_MIN_PACKETS = 5           # >= this many packets in the window is "live"
QUIET_DEMOTE_SECONDS = 300.0   # how long a live interface may go quiet first
RECONFIG_COOLDOWN = 120.0      # minimum seconds between Suricata reconfigures
MAX_CAPTURE_IFACES = 4         # bound the thread count on a multi-NIC deck
CLUSTER_ID_BASE = 90           # distinct af-packet fanout group per interface
VERIFY_GRACE_SECONDS = 20.0    # how long the engine gets before we ask it
CAPTURE_BLIND_SECONDS = 300.0  # attached, zero packets, for this long = blind

# ARPHRD_LOOPBACK. Loopback is excluded by TYPE rather than by the name "lo",
# because the name is a convention and the type is the kernel's own answer.
ARPHRD_LOOPBACK = 772


# ===========================================================================
# PURE: reading the kernel's counters
# ===========================================================================

def iface_type(name: str, root: Path = SYSFS_NET) -> int | None:
    """ARPHRD type for an interface, or None if it cannot be read."""
    try:
        return int(Path(root, name, "type").read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None


def is_loopback(name: str, root: Path = SYSFS_NET) -> bool:
    """True for loopback. Falls back to the name only when type is unreadable.

    The fallback matters: a deck mid-boot can expose a directory whose `type`
    is not yet readable, and guessing "not loopback" there would put lo into
    the capture set, where it would look live (every local socket writes to
    it) while seeing nothing of the network the operator cares about.
    """
    kind = iface_type(name, root)
    if kind is None:
        return name == "lo"
    return kind == ARPHRD_LOOPBACK


def list_interfaces(root: Path = SYSFS_NET) -> list[str]:
    """Candidate capture interfaces: everything in /sys/class/net but loopback.

    Deliberately NOT filtered by operstate, carrier or name. A bridge, a tap,
    a USB adapter and a Wi-Fi monitor interface are all legitimate things to
    watch on an incident deck, and "is it carrying packets" is a better test
    than any name pattern. An interface that is down carries nothing, so the
    rate test excludes it without a second rule that could disagree.
    """
    try:
        names = sorted(p.name for p in Path(root).iterdir())
    except OSError:
        return []
    return [n for n in names if not is_loopback(n, root)]


def rx_packets(name: str, root: Path = SYSFS_NET) -> int | None:
    """Lifetime received-packet counter, or None if unreadable/absent."""
    try:
        raw = Path(root, name, "statistics", "rx_packets").read_text(
            encoding="utf-8")
        return int(raw.strip())
    except (OSError, ValueError):
        return None


def sample_interfaces(root: Path = SYSFS_NET) -> dict[str, int]:
    """One snapshot: {interface: rx_packets} for every non-loopback device.

    Interfaces whose counter cannot be read are omitted rather than recorded
    as zero. Recording zero would manufacture a packet delta out of a read
    error the moment the counter became readable again.
    """
    out: dict[str, int] = {}
    for name in list_interfaces(root):
        count = rx_packets(name, root)
        if count is not None:
            out[name] = count
    return out


# ===========================================================================
# PURE: the heartbeat
# ===========================================================================

class InterfaceHeartbeat:
    """Which interfaces are carrying packets, and which should be captured.

    Fed snapshots; answers two separate questions on purpose:

      live(now)     — raw measurement. Is this interface carrying packets
                      right now, by the threshold?
      selected(now) — the policy answer, with hysteresis, pinning and the
                      interface cap applied. This is what Suricata is given.

    Keeping them apart is what makes the anti-thrash behaviour testable: a
    flapping interface changes live() on every flap and must not change
    selected() at all.
    """

    def __init__(self, window: float = LIVE_WINDOW,
                 min_packets: int = LIVE_MIN_PACKETS,
                 quiet_demote: float = QUIET_DEMOTE_SECONDS,
                 max_ifaces: int = MAX_CAPTURE_IFACES,
                 pinned: tuple[str, ...] = ()) -> None:
        self.window = float(window)
        self.min_packets = int(min_packets)
        self.quiet_demote = float(quiet_demote)
        self.max_ifaces = int(max_ifaces)
        self.pinned = tuple(pinned)
        self._samples: dict[str, deque] = {}
        self._promoted: dict[str, float] = {}   # iface -> last time it was live
        self.present: set[str] = set()
        self.last_sample = 0.0
        self.started = 0.0

    # --- ingest ---
    def observe(self, counts: dict[str, int], now: float) -> None:
        """Record one snapshot taken at `now`."""
        if not self.started:
            self.started = now
        self.last_sample = now
        self.present = set(counts)

        for name, value in counts.items():
            series = self._samples.setdefault(name, deque())
            if series and value < series[-1][1]:
                # The counter went backwards: driver reload, interface
                # recreated, or a 32-bit wrap. The old series describes a
                # different device lifetime, so it is not comparable.
                series.clear()
            series.append((now, int(value)))
            # Keep one sample older than the window as the measurement anchor,
            # so a full-window delta is available rather than a partial one.
            while len(series) > 2 and series[1][0] <= now - self.window:
                series.popleft()

        # An interface that vanished keeps no series: a USB NIC unplugged and
        # replugged is a new device, and its old counter is meaningless.
        for name in [n for n in self._samples if n not in counts]:
            del self._samples[name]

    # --- measurement ---
    def rates(self, now: float) -> dict[str, dict]:
        """Per-interface packet delta, span and rate over the window."""
        out: dict[str, dict] = {}
        for name, series in self._samples.items():
            if len(series) < 2:
                out[name] = {"packets": 0, "seconds": 0.0, "rate": 0.0,
                             "live": False, "samples": len(series)}
                continue
            t0, v0 = series[0]
            t1, v1 = series[-1]
            span = max(0.0, t1 - t0)
            packets = max(0, v1 - v0)
            rate = (packets / span) if span > 0 else 0.0
            out[name] = {"packets": packets, "seconds": round(span, 1),
                         "rate": round(rate, 3),
                         "live": packets >= self.min_packets,
                         "samples": len(series)}
        return out

    def live(self, now: float) -> set[str]:
        """Interfaces meeting the threshold on the current measurement."""
        return {n for n, r in self.rates(now).items() if r["live"]}

    # --- policy ---
    def selected(self, now: float) -> tuple[str, ...]:
        """The interfaces Suricata should capture on, with hysteresis applied.

        Pinned interfaces are included whenever they exist, live or not: the
        operator asked for them, and a SPAN port that is silent between
        probes is exactly the case the liveness test cannot judge. A pinned
        interface that does not exist is NOT included, because one unopenable
        device fails the entire engine.
        """
        for name in self.live(now):
            self._promoted[name] = now

        # Drop anything that vanished, and anything quiet past the hold time.
        for name in list(self._promoted):
            if name not in self.present:
                del self._promoted[name]
            elif (now - self._promoted[name]) > self.quiet_demote:
                del self._promoted[name]

        chosen = set(self._promoted)
        chosen |= {n for n in self.pinned if n in self.present}

        if len(chosen) > self.max_ifaces:
            # Keep the busiest. A deck with twenty veths should watch the
            # uplink, not spawn capture threads for all twenty.
            rates = self.rates(now)
            ranked = sorted(
                chosen,
                key=lambda n: (n in self.pinned,
                               rates.get(n, {}).get("packets", 0)),
                reverse=True)
            chosen = set(ranked[:self.max_ifaces])

        return tuple(sorted(chosen))

    def status(self, now: float) -> dict:
        """Evidence for the status file and for --detail on the bus."""
        rates = self.rates(now)
        return {
            "candidates": sorted(self.present),
            "live": sorted(self.live(now)),
            "selected": list(self.selected(now)),
            "pinned": list(self.pinned),
            "window_seconds": self.window,
            "min_packets": self.min_packets,
            "observed_seconds": round(max(0.0, now - self.started), 1),
            "rates": {n: rates[n]["rate"] for n in sorted(rates)},
            "packets": {n: rates[n]["packets"] for n in sorted(rates)},
        }


# ===========================================================================
# PURE: rendering the generated af-packet include
# ===========================================================================

GENERATED_HEADER = (
    "%YAML 1.1\n"
    "---\n"
    "# GENERATED BY orionx-postured (DEC-PHASE12-038). DO NOT HAND-EDIT.\n"
    "#\n"
    "# Rewritten whenever the set of interfaces measurably carrying packets\n"
    "# changes. To pin an interface permanently, pass --capture-iface <name>\n"
    "# to orionx-postured instead; a pinned interface skips the liveness\n"
    "# test but must still exist.\n"
    "#\n"
    "# Suricata requires an included file to begin with the two lines above:\n"
    "#   Error: conf-yaml-loader: The configuration file must begin with the\n"
    "#   following two lines: %YAML 1.1 and ---\n"
    "#\n"
    "# cluster-id is distinct per interface and that is load-bearing. Two\n"
    "# entries sharing one id fail with 'failed to set fanout mode: Invalid\n"
    "# argument' and take the whole engine down, not just that interface.\n"
)

# The capture settings applied to every interface. tpacket-v3 is what the
# engine itself asks for ("AF_PACKET tpacket-v3 is recommended for non-inline
# operation" on every start without it); checksum-checks: kernel trusts the
# NIC's own offload verdict, which is what Debian's default does.
IFACE_SETTINGS = (
    ("cluster-type", "cluster_flow"),
    ("defrag", "yes"),
    ("use-mmap", "yes"),
    ("tpacket-v3", "yes"),
    ("checksum-checks", "kernel"),
)

BASELINE_BODY = (
    "af-packet:\n"
    "  - interface: default\n"
    + "".join(f"    {k}: {v}\n" for k, v in IFACE_SETTINGS)
)


def allocate_cluster_ids(ifaces, base: int = CLUSTER_ID_BASE) -> list[tuple]:
    """[(interface, cluster_id)] with one distinct id per interface."""
    return [(name, base + i) for i, name in enumerate(sorted(set(ifaces)))]


def render_interfaces_yaml(ifaces, base: int = CLUSTER_ID_BASE) -> str:
    """The generated include, as text.

    Carries NO timestamp and no ordering that depends on discovery order.
    The same interface set must render byte-identically every time, because
    byte equality is how the writer decides not to restart the engine.

    An empty set renders the baseline: the `default` entry alone, which is
    settings-only and not a capture device. Suricata rejects that at start
    ("No interface found in config for af-packet", exit 1), which is correct
    and is why the caller must not start it in that state.
    """
    names = sorted(set(n for n in ifaces if n))
    if not names:
        return GENERATED_HEADER + "#\n# No interface is carrying traffic.\n" \
            + BASELINE_BODY
    out = [GENERATED_HEADER, "af-packet:\n"]
    for name, cid in allocate_cluster_ids(names, base):
        out.append(f"  - interface: {name}\n")
        out.append(f"    cluster-id: {cid}\n")
        out.extend(f"    {k}: {v}\n" for k, v in IFACE_SETTINGS)
    return "".join(out)


def write_interfaces_yaml(ifaces, path: Path = INTERFACES_YAML,
                          base: int = CLUSTER_ID_BASE,
                          dry_run: bool = False) -> dict:
    """Write the include if and only if its content would change.

    Returns {"ok", "changed", "path", "interfaces", "error"}. Idempotent by
    content comparison rather than by remembering what we last wrote, so a
    file edited or lost behind our back is repaired on the next pass
    (RESILIENCE.md rule 2: re-read reality, do not trust the last apply).
    """
    names = sorted(set(n for n in ifaces if n))
    body = render_interfaces_yaml(names, base)
    path = Path(path)
    result = {"ok": True, "changed": False, "path": str(path),
              "interfaces": names, "error": None}
    try:
        current = path.read_text(encoding="utf-8")
    except OSError:
        current = None
    if current == body:
        return result
    result["changed"] = True
    if dry_run:
        print(f"[dry-run] write {path}: af-packet={names or 'none'}",
              flush=True)
        return result
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(body, encoding="utf-8")
        os.replace(tmp, path)
    except OSError as exc:
        result["ok"] = False
        result["error"] = str(exc)
    return result


# ===========================================================================
# PURE: what `suricata -T` actually told us
# ===========================================================================

def classify_config_test(returncode: int | None, output: str) -> dict:
    """Turn a `suricata -T` run into a verdict. The exit code is not enough.

    Measured on suricata 7.0.10 with Debian's own stock suricata.yaml: a
    config that is completely valid exits 1 when no rule file matched, and
    prints only

      W: detect: No rule files match the pattern /var/lib/suricata/rules/...

    A fresh Orion-X deck is in exactly that state until orionx-freshen-
    suricata runs, so gating the start on the exit code would refuse to start
    a working IDS on every deck that has not fetched ET-Open yet. The verdict
    comes from the diagnostics instead:

      "invalid"  — any Error:/E: line. The config genuinely will not load.
      "no-rules" — valid, but nothing to match on. Not a capture problem;
                   DEC-PHASE12-024's rules warning already owns that fact.
      "ok"       — the engine said it loaded the configuration.
    """
    text = output or ""
    errors = [ln.strip() for ln in text.splitlines()
              if ln.startswith("Error:") or ln.startswith("E: ")]
    if errors:
        return {"verdict": "invalid", "error": errors[0], "rc": returncode}
    if "successfully loaded" in text:
        return {"verdict": "ok", "error": None, "rc": returncode}
    if "no rules were loaded" in text or "No rule files match" in text:
        return {"verdict": "no-rules", "error": None, "rc": returncode}
    if returncode == 0:
        return {"verdict": "ok", "error": None, "rc": returncode}
    tail = text.strip().splitlines()[-1:] or [""]
    return {"verdict": "invalid", "error": tail[0], "rc": returncode}


def check_config(config: Path = ORIONX_YAML, runner=subprocess.run,
                binary: str = SURICATA_BIN) -> dict:
    """Run `suricata -T -v` against a config and classify the result."""
    try:
        res = runner([binary, "-T", "-v", "-c", str(config)],
                     capture_output=True, text=True, timeout=120, check=False)
    except FileNotFoundError:
        return {"verdict": "absent", "error": f"{binary} is not installed",
                "rc": None}
    except (OSError, subprocess.SubprocessError) as exc:
        return {"verdict": "unknown", "error": str(exc), "rc": None}
    return classify_config_test(res.returncode,
                                (res.stdout or "") + (res.stderr or ""))


# ===========================================================================
# PURE + EFFECT: asking the RUNNING engine what it attached to
# ===========================================================================

def parse_sc_response(text: str | None) -> dict | None:
    """One suricatasc JSON reply, or None. Never raises."""
    if not text:
        return None
    for line in reversed(text.strip().splitlines()):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if isinstance(rec, dict):
            return rec
    return None


def parse_iface_list(text: str | None) -> list[str] | None:
    """Interfaces the running engine reports attaching to, or None.

    Measured shape (suricata 7.0.10, `suricatasc -c iface-list`):
      {"message": {"count": 2, "ifaces": ["eth0", "dummy0"]}, "return": "OK"}

    None means "could not be determined" and must never be reported as an
    empty capture set: "the engine told me it has no interfaces" and "I could
    not ask" are different facts with different remedies.
    """
    rec = parse_sc_response(text)
    if not rec or rec.get("return") != "OK":
        return None
    msg = rec.get("message")
    if not isinstance(msg, dict):
        return None
    ifaces = msg.get("ifaces")
    if not isinstance(ifaces, list):
        return None
    return [str(i) for i in ifaces]


def parse_iface_stat(text: str | None) -> dict | None:
    """Per-interface counters, or None.

    Measured shape (`suricatasc -c "iface-stat eth0"`):
      {"message": {"pkts": 8, "invalid-checksums": 0, "drop": 0,
                   "bypassed": 0}, "return": "OK"}
    """
    rec = parse_sc_response(text)
    if not rec or rec.get("return") != "OK":
        return None
    msg = rec.get("message")
    if not isinstance(msg, dict) or "pkts" not in msg:
        return None
    try:
        return {"pkts": int(msg.get("pkts") or 0),
                "drop": int(msg.get("drop") or 0)}
    except (TypeError, ValueError):
        return None


def command_socket(paths=(COMMAND_SOCKET, STOCK_COMMAND_SOCKET)) -> Path | None:
    """First existing command socket, or None."""
    for path in paths:
        try:
            if Path(path).exists():
                return Path(path)
        except OSError:
            continue
    return None


def suricatasc(command: str, socket_path: Path, runner=subprocess.run,
               binary: str = SURICATASC_BIN) -> str | None:
    """Raw stdout of one suricatasc command, or None on any failure."""
    try:
        res = runner([binary, "-c", command, str(socket_path)],
                     capture_output=True, text=True, timeout=10, check=False)
    except FileNotFoundError:
        return None
    except (OSError, subprocess.SubprocessError):
        return None
    return (res.stdout or "") + (res.stderr or "")


def verify_capture(desired, socket_path: Path | None = None,
                   runner=subprocess.run, binary: str = SURICATASC_BIN) -> dict:
    """Ask the running engine what it is actually capturing on.

    This is the whole point of RESILIENCE.md rules 1 and 3 for this
    subsystem. `systemctl start suricata` exiting 0 means systemd forked a
    process; it says nothing about whether a capture socket was opened on the
    interface we asked for. The engine's own iface-list does.

    Returns a dict whose `verified` field is tri-state on purpose:
      True  — the engine confirmed every desired interface is attached.
      False — the engine answered, and the answer is wrong.
      None  — we could not ask. NOT success, and never reported as success.
    """
    want = sorted(set(desired or ()))
    out = {"verified": None, "method": "unix-socket", "attached": [],
           "missing": want, "extra": [], "packets": {}, "total_packets": 0,
           "socket": str(socket_path) if socket_path else None,
           "reason": None}
    if socket_path is None:
        socket_path = command_socket()
        out["socket"] = str(socket_path) if socket_path else None
    if socket_path is None:
        out["method"] = "none"
        out["reason"] = "no suricata command socket exists"
        return out

    attached = parse_iface_list(
        suricatasc("iface-list", socket_path, runner, binary))
    if attached is None:
        out["method"] = "none"
        out["reason"] = "suricatasc could not read iface-list"
        return out

    out["attached"] = sorted(attached)
    out["missing"] = [n for n in want if n not in attached]
    out["extra"] = [n for n in attached if n not in want]
    for name in attached:
        stat = parse_iface_stat(
            suricatasc(f"iface-stat {name}", socket_path, runner, binary))
        if stat is not None:
            out["packets"][name] = stat["pkts"]
    out["total_packets"] = sum(out["packets"].values())
    out["verified"] = not out["missing"] and bool(attached)
    if out["missing"]:
        out["reason"] = ("engine is not attached to "
                         + ", ".join(out["missing"]))
    return out


# ===========================================================================
# PURE: honest degradation (RESILIENCE.md rule 8)
# ===========================================================================
#
# Every message below owes four things: what is not working, what the
# consequence is, what still works, and the exact command that fixes it.
# "What still works" is not padding — orionx-scanwatch (DEC-PHASE12-022)
# detects port scans from the kernel's own drop log with no interface, no
# rules and no network, so a Suricata failure is a partial loss of coverage
# and saying otherwise would be its own kind of dishonesty.
#
# All of these are published in category `health`, never `ids`. `ids` feeds
# the Cockpit's THREAT PRESSURE gauge and `health` deliberately does not
# (DEC-PHASE12-034, RESILIENCE.md rule 5). A deck that frightens itself with
# its own self-diagnosis teaches the operator to ignore the gauge.

SCANWATCH_NOTE = ("Port-scan detection via orionx-scanwatch is unaffected: "
                  "it reads the firewall drop log and needs no interface.")


def _rate_summary(status: dict, limit: int = 6) -> str:
    rates = status.get("rates") or {}
    if not rates:
        return "no interfaces present"
    items = sorted(rates.items(), key=lambda kv: (-kv[1], kv[0]))[:limit]
    return ", ".join(f"{name} {rate:.2f} pkt/s" for name, rate in items)


def no_live_message(status: dict, tier_label: str) -> tuple[str, str, dict]:
    """No interface is carrying packets, so Suricata was not started."""
    detail = {"reason": "no-live-interface",
              "candidates": status.get("candidates", []),
              "rates": status.get("rates", {}),
              "window_seconds": status.get("window_seconds"),
              "min_packets": status.get("min_packets"),
              "observed_seconds": status.get("observed_seconds")}
    msg = (
        f"Suricata was NOT started while {tier_label} is selected: no network "
        f"interface is carrying traffic "
        f"({_rate_summary(status)}; threshold "
        f"{status.get('min_packets')} packets in "
        f"{status.get('window_seconds')}s). Starting it anyway would exit 1 "
        "immediately ('No interface found in config for af-packet'). "
        "Consequence: NO IDS coverage. "
        + SCANWATCH_NOTE +
        " Remedy: connect the capture interface, then `ip link set <iface> "
        "up`; or watch a deliberately silent port with "
        "`orionx-postured --capture-iface <iface>`. "
        "Check what the deck can see: `ip -br link`."
    )
    return "warning", msg, detail


def absent_message(tier_label: str) -> tuple[str, str, dict]:
    """The suricata binary is not on this image at all."""
    msg = (
        f"Suricata is NOT INSTALLED on this deck, while {tier_label} is "
        "selected. Consequence: no signature-based detection of any kind, "
        "and the tier is claiming coverage the deck does not have. "
        + SCANWATCH_NOTE +
        " Remedy: `sudo apt-get install suricata` on a connected node, or "
        "drop to Tier 0 so the posture matches reality."
    )
    return "critical", msg, {"reason": "suricata-absent"}


def invalid_config_message(verdict: dict, config: Path = ORIONX_YAML,
                           ) -> tuple[str, str, dict]:
    """`suricata -T` rejected the configuration."""
    err = verdict.get("error") or "unspecified configuration error"
    msg = (
        f"Suricata REJECTED its configuration ({config}): {err}. "
        "Consequence: the IDS cannot start, so there is no signature-based "
        "detection. "
        + SCANWATCH_NOTE +
        f" Remedy: `sudo suricata -T -v -c {config}` shows the full "
        f"diagnosis; the generated interface list is {INTERFACES_YAML} and "
        "is rewritten from scratch on the next reconfigure, so deleting it "
        "is safe."
    )
    return "critical", msg, {"reason": "config-rejected",
                             "config": str(config), "error": err}


def capture_ok_message(verify: dict, tier_label: str) -> tuple[str, str, dict]:
    """Confirmed: the engine is attached to what we asked for."""
    ifaces = ", ".join(verify.get("attached") or []) or "nothing"
    msg = (
        f"Suricata is capturing on {ifaces} "
        f"({verify.get('total_packets', 0)} packets seen by the engine so "
        f"far) under {tier_label}. Confirmed by asking the running engine, "
        "not by the exit status of systemctl."
    )
    return "notice", msg, {"reason": "capture-verified",
                           "attached": verify.get("attached"),
                           "packets": verify.get("packets")}


def capture_mismatch_message(verify: dict, desired,
                             tier_label: str) -> tuple[str, str, dict]:
    """The engine answered, and it is not watching what we asked for."""
    want = ", ".join(sorted(desired)) or "nothing"
    got = ", ".join(verify.get("attached") or []) or "nothing"
    msg = (
        f"Suricata is running but NOT attached to the interface(s) Orion-X "
        f"asked for: wanted {want}, engine reports {got}. Consequence: "
        "traffic on the missing interface(s) is not inspected, and the deck "
        "would otherwise look fully covered. "
        + SCANWATCH_NOTE +
        " Remedy: `sudo systemctl restart suricata` then "
        "`sudo suricatasc -c iface-list " + str(COMMAND_SOCKET) + "`; if it "
        f"keeps disagreeing, inspect {INTERFACES_YAML}."
    )
    return "warning", msg, {"reason": "iface-mismatch", "desired": sorted(desired),
                            "attached": verify.get("attached"),
                            "missing": verify.get("missing")}


def capture_blind_message(verify: dict, seconds: float,
                          ) -> tuple[str, str, dict]:
    """Attached, running, and has not seen a single packet."""
    ifaces = ", ".join(verify.get("attached") or []) or "nothing"
    msg = (
        f"Suricata has been attached to {ifaces} for {seconds / 60:.0f} "
        "minutes and the engine has processed ZERO packets. That is not a "
        "quiet network, it is a sensor that is probably not seeing the "
        "traffic you think it is — check a mirror/SPAN port, a NIC in the "
        "wrong VLAN, or an interface that is up but unplugged. "
        + SCANWATCH_NOTE +
        " Remedy: `sudo tcpdump -ni " + (verify.get("attached") or ["<iface>"])[0]
        + " -c 5` — if tcpdump sees nothing either, the problem is upstream "
        "of Suricata."
    )
    return "warning", msg, {"reason": "capture-blind",
                            "attached": verify.get("attached"),
                            "seconds": round(seconds, 1)}


def unverified_message(verify: dict, desired) -> tuple[str, str, dict]:
    """Running, but we could not get the engine to confirm anything."""
    want = ", ".join(sorted(desired)) or "nothing"
    msg = (
        f"Suricata is running and was asked to capture on {want}, but this "
        f"could NOT be verified: {verify.get('reason') or 'no answer'}. "
        "Treat IDS coverage as unconfirmed rather than present — the engine "
        "may be attached to nothing. "
        + SCANWATCH_NOTE +
        " Remedy: `sudo suricatasc -c iface-list " + str(COMMAND_SOCKET)
        + "`; if the socket is missing, check that "
        "/etc/suricata/orionx.yaml sets unix-command.enabled: yes and that "
        "`systemctl cat suricata` shows the orionx-capture.conf drop-in."
    )
    return "warning", msg, {"reason": "capture-unverified",
                            "desired": sorted(desired),
                            "detail": verify.get("reason")}


# ===========================================================================
# The anti-thrash brake
# ===========================================================================

class ReconfigureBrake:
    """One reconfigure per cooldown, and never one that changes nothing.

    Separate from the heartbeat because they answer different questions and
    fail in different ways: the heartbeat decides WHAT should be captured,
    this decides WHETHER now is an acceptable moment to act on a change. A
    restart is a gap in coverage, so the answer is "no" far more often than
    the set changes.

    A vanished interface overrides the cooldown. Hysteresis cannot help
    there: the device is gone, the engine's thread for it has already failed,
    and one failed device fails the whole engine at the next start. Waiting
    out a cooldown would mean waiting with no capture at all.
    """

    def __init__(self, cooldown: float = RECONFIG_COOLDOWN) -> None:
        self.cooldown = float(cooldown)
        self.applied: tuple[str, ...] | None = None
        self.last_apply = 0.0
        self.deferred: tuple[str, ...] | None = None
        self.suppressed = 0

    def decide(self, desired: tuple[str, ...], now: float,
               present: set[str] | None = None) -> dict:
        """Should the caller reconfigure right now, and why or why not."""
        desired = tuple(sorted(desired))
        if self.applied is not None and desired == self.applied:
            self.deferred = None
            return {"act": False, "reason": "unchanged", "desired": desired}

        # Something we are currently capturing on no longer exists.
        vanished = ()
        if self.applied is not None and present is not None:
            vanished = tuple(n for n in self.applied if n not in present)

        if self.applied is None:
            return {"act": True, "reason": "first-apply", "desired": desired}
        if vanished:
            return {"act": True, "reason": "interface-vanished",
                    "desired": desired, "vanished": list(vanished)}
        if (now - self.last_apply) < self.cooldown:
            self.deferred = desired
            self.suppressed += 1
            return {"act": False, "reason": "cooldown", "desired": desired,
                    "retry_in": round(self.cooldown - (now - self.last_apply),
                                      1)}
        return {"act": True, "reason": "changed", "desired": desired}

    def note_applied(self, desired: tuple[str, ...], now: float) -> None:
        self.applied = tuple(sorted(desired))
        self.last_apply = now
        self.deferred = None

    def status(self) -> dict:
        return {"applied": list(self.applied or ()),
                "cooldown_seconds": self.cooldown,
                "deferred": list(self.deferred or ()),
                "suppressed_reconfigures": self.suppressed}
