#!/usr/bin/env python3
"""
Orion-X Phoenix Edition — PCAP Analyzer
========================================
Structured Traffic Analysis (STA) of packet captures using tshark (primary)
and tcpdump (supplementary), following the Bejtlich methodology.

Usage examples:
    pcap-analyzer.py capture.pcap
    pcap-analyzer.py capture.pcap --output-dir ~/Analysis/incident-2026/
    pcap-analyzer.py capture.pcap --quick
    pcap-analyzer.py capture.pcap --report ~/reports/summary.txt

Analysis phases (Bejtlich STA pattern):
    Phase 1: Capture metadata     — packet count, time range, byte totals
    Phase 2: Protocol hierarchy   — protocol distribution via io,phs
    Phase 3: Conversations        — top IP and TCP talkers (conv,ip / conv,tcp)
    Phase 4: Endpoints            — IP endpoint table (endpoints,ip)
    Phase 5: App-layer overview   — HTTP, DNS, TLS statistics (skipped with --quick)
    Phase 6: Readable summary     — tcpdump first-200 packet human-readable dump
                                    (only when tcpdump is present on PATH)

Outputs:
    <output-dir>/
        01-metadata.txt         — Phase 1 tshark io,stat,0
        02-protocols.txt        — Phase 2 protocol hierarchy
        03-conversations-ip.txt — Phase 3 IP conversations
        03-conversations-tcp.txt— Phase 3 TCP conversations
        04-endpoints-ip.txt     — Phase 4 IP endpoints
        05-http.txt             — Phase 5 HTTP stats (omitted with --quick)
        05-dns.txt              — Phase 5 DNS stats  (omitted with --quick)
        05-tls.txt              — Phase 5 TLS stats  (omitted with --quick)
        06-tcpdump-head.txt     — Phase 6 tcpdump readable (when available)
        summary.txt             — Consolidated overview of all phases
    Each file begins with a chain-of-custody header (pcap name, SHA-256,
    analysis timestamp, hostname, tool versions).

Exit codes:
    0  — analysis complete (all required phases ran)
    1  — input validation failure (file not found, not readable)
    2  — required tool missing (tshark not on PATH)

@decision DEC-PHASE9-017
@title W9-2a gecko-legacy port: pcap-analyzer.py — modernized STA tool
@status accepted
@rationale The gecko/bin/analyze-pcap.sh (circa 2009–2010) ran argus, dsniff,
    chaosreader, sancp, snort, ettercap, ngrep, p0f, and many other tools that
    are either obsolete, out-of-package, or require complex system-level config
    that does not belong in a live ISO. The Orion-X ISO already ships tshark
    (wireshark package) and tcpdump — both are first-class PCAP analysis tools.
    This rewrite delivers the same operator value (structured per-phase output,
    summary table, chain-of-custody header) using only what is already present
    on the live system, with a clean Python argparse CLI instead of an
    interactive bash prompt. No shell-idiom literal port; this is a clean
    Python 3 tool using stdlib only (no extra pip deps). The gecko shell script
    is reference-only and is NOT staged into the ISO.
"""

# PEP 563: defer annotation evaluation so PEP 604 union syntax (X | None) works
# on Debian Bullseye Python 3.9 without `Optional[X]`. @decision DEC-PHASE9-019.
from __future__ import annotations

import argparse
import datetime
import hashlib
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import textwrap

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_TOOL_TSHARK = "tshark"
_TOOL_TCPDUMP = "tcpdump"

# Phases emitted by run_phases(); each entry: (filename, label, args)
# args is a list of tshark arguments (after -r <pcap>); None means
# the phase uses tcpdump or is handled specially.

_VERSION = "2.0.0-rc4"


# ---------------------------------------------------------------------------
# Chain-of-custody header
# ---------------------------------------------------------------------------

def _tool_version(tool: str) -> str:
    """Return a one-line version string for *tool*, best-effort."""
    try:
        result = subprocess.run(
            [tool, "--version"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        first_line = (result.stdout or result.stderr or "unknown").splitlines()[0]
        return first_line.strip()
    except Exception:
        return "unknown"


def build_custody_header(pcap_path: pathlib.Path, tool_versions: dict) -> str:
    """Return a chain-of-custody block for the top of every output file."""
    sha256 = _sha256(pcap_path)
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    hostname = _best_effort_hostname()
    lines = [
        "=" * 72,
        "Orion-X Phoenix Edition — PCAP Analyzer",
        f"Version       : {_VERSION}",
        f"File          : {pcap_path.name}",
        f"SHA-256       : {sha256}",
        f"Analysis time : {ts}",
        f"Host          : {hostname}",
    ]
    for name, ver in tool_versions.items():
        lines.append(f"Tool ({name:<8}): {ver}")
    lines.append("=" * 72)
    lines.append("")
    return "\n".join(lines)


def _sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _best_effort_hostname() -> str:
    try:
        return socket.gethostname()
    except Exception:
        return "unknown"


# ---------------------------------------------------------------------------
# Tool discovery
# ---------------------------------------------------------------------------

def discover_tools() -> dict:
    """
    Return a dict of tool_name -> path (or None).
    Fails loudly if tshark is missing — it is the core dependency.
    """
    tools = {}
    for name in [_TOOL_TSHARK, _TOOL_TCPDUMP]:
        path = shutil.which(name)
        tools[name] = path
    if tools[_TOOL_TSHARK] is None:
        print(
            "ERROR: tshark not found on PATH. "
            "Install wireshark-common (tshark) to use pcap-analyzer.",
            file=sys.stderr,
        )
        sys.exit(2)
    return tools


# ---------------------------------------------------------------------------
# Subprocess runner
# ---------------------------------------------------------------------------

def run_tshark(args: list, pcap_path: pathlib.Path, timeout: int = 120) -> str:
    """Run tshark with *args* against *pcap_path*. Return stdout (may be empty)."""
    cmd = [_TOOL_TSHARK, "-r", str(pcap_path)] + args
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if result.returncode != 0:
            stderr_snippet = result.stderr.strip()[:500] if result.stderr else ""
            return f"[tshark exited {result.returncode}]\n{stderr_snippet}\n"
        return result.stdout
    except subprocess.TimeoutExpired:
        return f"[tshark timed out after {timeout}s for args: {args}]\n"
    except FileNotFoundError:
        return "[tshark not found]\n"


def run_tcpdump(pcap_path: pathlib.Path, max_packets: int = 200) -> str:
    """Run tcpdump readable summary. Returns output or an informational note."""
    if shutil.which(_TOOL_TCPDUMP) is None:
        return "[tcpdump not on PATH — phase 6 skipped]\n"
    cmd = [_TOOL_TCPDUMP, "-r", str(pcap_path), "-nn", "-tttt", "-c", str(max_packets)]
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=60,
        )
        # tcpdump writes summaries to stderr; stdout may be empty
        output = result.stdout or result.stderr or ""
        if result.returncode != 0 and not output.strip():
            return f"[tcpdump exited {result.returncode} with no output]\n"
        return output
    except subprocess.TimeoutExpired:
        return "[tcpdump timed out]\n"
    except FileNotFoundError:
        return "[tcpdump not found]\n"


# ---------------------------------------------------------------------------
# Output directory
# ---------------------------------------------------------------------------

def resolve_output_dir(pcap_path: pathlib.Path, output_dir_arg: str | None) -> pathlib.Path:
    if output_dir_arg:
        out = pathlib.Path(output_dir_arg).expanduser()
    else:
        ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        stem = pcap_path.stem
        out = pathlib.Path.home() / "Analysis" / f"{stem}-{ts}"
    out.mkdir(parents=True, exist_ok=True)
    return out


# ---------------------------------------------------------------------------
# Phase runners
# ---------------------------------------------------------------------------

def run_phases(
    pcap_path: pathlib.Path,
    output_dir: pathlib.Path,
    custody_header: str,
    quick: bool,
) -> list:
    """
    Execute all analysis phases. Returns a list of (label, filename, excerpt)
    tuples for the summary report.
    """
    results = []

    def write_phase(filename: str, label: str, content: str) -> tuple:
        filepath = output_dir / filename
        filepath.write_text(custody_header + content, encoding="utf-8")
        # Excerpt: first 15 non-empty lines for the summary
        meaningful = [ln for ln in content.splitlines() if ln.strip()][:15]
        excerpt = "\n".join(meaningful)
        print(f"  [phase] {label} -> {filename}")
        return label, filename, excerpt

    # Phase 1: Capture metadata
    label = "Phase 1: Capture metadata"
    print(f"\n[pcap-analyzer] {label}")
    raw = run_tshark(["-q", "-z", "io,stat,0"], pcap_path)
    results.append(write_phase("01-metadata.txt", label, raw))

    # Phase 2: Protocol hierarchy
    label = "Phase 2: Protocol hierarchy"
    print(f"[pcap-analyzer] {label}")
    raw = run_tshark(["-q", "-z", "io,phs"], pcap_path)
    results.append(write_phase("02-protocols.txt", label, raw))

    # Phase 3a: IP conversations
    label = "Phase 3a: IP conversations"
    print(f"[pcap-analyzer] {label}")
    raw = run_tshark(["-q", "-z", "conv,ip"], pcap_path)
    results.append(write_phase("03-conversations-ip.txt", label, raw))

    # Phase 3b: TCP conversations
    label = "Phase 3b: TCP conversations"
    print(f"[pcap-analyzer] {label}")
    raw = run_tshark(["-q", "-z", "conv,tcp"], pcap_path)
    results.append(write_phase("03-conversations-tcp.txt", label, raw))

    # Phase 4: IP endpoints
    label = "Phase 4: IP endpoints"
    print(f"[pcap-analyzer] {label}")
    raw = run_tshark(["-q", "-z", "endpoints,ip"], pcap_path)
    results.append(write_phase("04-endpoints-ip.txt", label, raw))

    if not quick:
        # Phase 5a: HTTP overview
        label = "Phase 5a: HTTP overview"
        print(f"[pcap-analyzer] {label}")
        raw = run_tshark(["-q", "-z", "http,tree"], pcap_path)
        results.append(write_phase("05-http.txt", label, raw))

        # Phase 5b: DNS overview
        label = "Phase 5b: DNS overview"
        print(f"[pcap-analyzer] {label}")
        raw = run_tshark(["-q", "-z", "dns,tree"], pcap_path)
        results.append(write_phase("05-dns.txt", label, raw))

        # Phase 5c: TLS/SSL handshake overview
        label = "Phase 5c: TLS/SSL overview"
        print(f"[pcap-analyzer] {label}")
        raw = run_tshark(["-q", "-z", "ssl,stat,0"], pcap_path)
        results.append(write_phase("05-tls.txt", label, raw))
    else:
        print("[pcap-analyzer] Phase 5 (HTTP/DNS/TLS) skipped — --quick mode")

    # Phase 6: tcpdump readable head (optional)
    label = "Phase 6: tcpdump readable head"
    print(f"[pcap-analyzer] {label}")
    raw = run_tcpdump(pcap_path)
    results.append(write_phase("06-tcpdump-head.txt", label, raw))

    return results


# ---------------------------------------------------------------------------
# Summary report
# ---------------------------------------------------------------------------

def write_summary(
    pcap_path: pathlib.Path,
    output_dir: pathlib.Path,
    custody_header: str,
    phase_results: list,
    report_path: str | None,
) -> None:
    """Write a human-readable summary of all phases."""
    lines = [custody_header]
    lines.append(f"PCAP Analysis Summary — {pcap_path.name}")
    lines.append(f"Output directory: {output_dir}")
    lines.append("")
    lines.append("Files produced:")
    for label, filename, _ in phase_results:
        lines.append(f"  {filename:<30} {label}")
    lines.append("")
    lines.append("Phase excerpts:")
    lines.append("-" * 72)
    for label, filename, excerpt in phase_results:
        lines.append(f"\n--- {label} ({filename}) ---")
        if excerpt:
            lines.append(textwrap.indent(excerpt, "  "))
        else:
            lines.append("  (no output)")
    lines.append("")
    lines.append("=" * 72)
    lines.append("Analysis complete.")
    text = "\n".join(lines)

    summary_file = output_dir / "summary.txt"
    summary_file.write_text(text, encoding="utf-8")
    print(f"\n[pcap-analyzer] Summary written to: {summary_file}")

    if report_path:
        rp = pathlib.Path(report_path).expanduser()
        rp.parent.mkdir(parents=True, exist_ok=True)
        rp.write_text(text, encoding="utf-8")
        print(f"[pcap-analyzer] Report also written to: {rp}")


# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

def validate_input(pcap_file: str) -> pathlib.Path:
    """
    Validate that *pcap_file* exists, is readable, and is a regular file.
    Fails loudly (exit 1) if validation fails.
    """
    path = pathlib.Path(pcap_file).expanduser()
    if not path.exists():
        print(f"ERROR: PCAP file not found: {path}", file=sys.stderr)
        sys.exit(1)
    if not path.is_file():
        print(f"ERROR: Not a regular file: {path}", file=sys.stderr)
        sys.exit(1)
    if not os.access(path, os.R_OK):
        print(f"ERROR: PCAP file is not readable: {path}", file=sys.stderr)
        sys.exit(1)
    if path.stat().st_size == 0:
        print(f"ERROR: PCAP file is empty (0 bytes): {path}", file=sys.stderr)
        sys.exit(1)
    return path


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pcap-analyzer.py",
        description=textwrap.dedent("""\
            Orion-X PCAP Analyzer — Structured Traffic Analysis (Bejtlich STA method)

            Analyzes a packet capture through six structured phases using tshark
            (required) and tcpdump (optional). Each phase writes a dedicated output
            file with a chain-of-custody header. A summary report collects excerpts
            from all phases.

            Analysis phases:
              Phase 1  Capture metadata  (tshark io,stat,0)
              Phase 2  Protocol hierarchy (tshark io,phs)
              Phase 3  Conversations     (tshark conv,ip + conv,tcp)
              Phase 4  Endpoints         (tshark endpoints,ip)
              Phase 5  App-layer overview (tshark http,tree / dns,tree / ssl,stat,0)
                       [skipped with --quick]
              Phase 6  Readable head     (tcpdump -nn -tttt -c 200)
                       [skipped if tcpdump absent]
        """),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "pcap_file",
        help="Path to the PCAP/PCAPNG file to analyze",
    )
    parser.add_argument(
        "--output-dir",
        metavar="DIR",
        default=None,
        help=(
            "Directory to write phase output files and summary. "
            "Default: ~/Analysis/<pcap-stem>-<timestamp>/"
        ),
    )
    parser.add_argument(
        "--quick",
        action="store_true",
        default=False,
        help="Skip Phase 5 (HTTP/DNS/TLS) for a faster analysis run",
    )
    parser.add_argument(
        "--report",
        metavar="PATH",
        default=None,
        help="Additionally write the summary report to this path",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    # --- Input validation first (exit 1 on bad file, before tool check) ---
    # Ordering matters: validate_input exits 1; discover_tools exits 2.
    # Tests that assert exit-1 on a missing file must not require tshark on PATH.
    pcap_path = validate_input(args.pcap_file)

    # --- Tool discovery (fails loud with exit 2 if tshark missing) ---
    tools = discover_tools()

    # --- Resolve output directory ---
    output_dir = resolve_output_dir(pcap_path, args.output_dir)
    print(f"[pcap-analyzer] Analyzing: {pcap_path}")
    print(f"[pcap-analyzer] Output dir: {output_dir}")

    # --- Build tool version map for chain-of-custody ---
    tool_versions = {}
    for name in [_TOOL_TSHARK, _TOOL_TCPDUMP]:
        if tools[name] is not None:
            tool_versions[name] = _tool_version(name)

    # --- Chain-of-custody header (written to every output file) ---
    custody_header = build_custody_header(pcap_path, tool_versions)

    # --- Run phases ---
    phase_results = run_phases(pcap_path, output_dir, custody_header, args.quick)

    # --- Summary ---
    write_summary(pcap_path, output_dir, custody_header, phase_results, args.report)

    print("[pcap-analyzer] Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
