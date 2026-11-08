#!/usr/bin/env python3
"""zeek_logs — where Zeek's logs are on this deck, and how to read a line of one.

The ONE authority for Zeek log discovery and record decoding. `orionx-postured`
(DEC-PHASE12-028 ingest, DEC-PHASE13-033 managed instances) and
`network_picture.py` (DEC-PHASE13-046, #93) both import from here; neither
carries its own copy of the candidate directories or the TSV/JSON decoder.
Two copies of "where does Zeek write" is how one surface reports detections
while another says Zeek is absent, so the functions below were lifted out of
the daemon verbatim rather than paraphrased into a second reader.

Pure apart from the filesystem reads the names announce. stdlib only.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

# --- Zeek (DEC-PHASE12-028) -------------------------------------------------
# Zeek may be absent, may arrive later, and may write its logs in any of
# several places depending on how it was started. All three are runtime
# questions, re-asked on every read.
#
# All readable sources are ingested; these are not mutually exclusive sensors.
# /opt/zeek/logs/current is zeekctl's live directory; /var/log/zeek/current is
# the convention an operator running `zeek -i` by hand is told to use by
# install-zeek.sh; /var/lib/orionx/zeek is where Orion-X's own offline runs go.
ZEEK_LOG_DIRS = (
    Path("/opt/zeek/logs/current"),
    Path("/var/log/zeek/current"),
    Path("/var/log/zeek"),
    Path("/var/lib/orionx/zeek"),
)
ZEEK_NOTICE_LOG = "notice.log"
ZEEK_WEIRD_LOG = "weird.log"
ZEEK_CONN_LOG = "conn.log"

# --- Zeek as a managed sensor (DEC-PHASE13-033, implements DEC-PHASE13-004) --
# orionx-zeek@<iface>.service runs Zeek on one interface with
# LogsDirectory=zeek/<iface>, so each instance writes /var/log/zeek/<iface>/.
# Log discovery expands ZEEK_INSTANCE_ROOT's subdirectories so a reader
# attaches to every instance directory without naming interfaces here.
ZEEK_INSTANCE_ROOT = Path("/var/log/zeek")
ZEEK_ARCHIVE_DIR = "archive"


def expand_zeek_log_dirs(dirs=None, instance_root: Path = ZEEK_INSTANCE_ROOT):
    """ZEEK_LOG_DIRS plus every instance directory under the instance root.

    Instance directories (/var/log/zeek/<iface>/) are inserted right before
    the root entry itself, sorted, with legacy zeekctl `current` and hand-run
    directories retained as additional sources. The bare root (where nothing
    writes any more) stays last. `archive` is a rotation target, never a
    live log directory, and is skipped. Pure apart from one listdir.
    """
    dirs = tuple(Path(d) for d in (ZEEK_LOG_DIRS if dirs is None else dirs))
    root = Path(instance_root)
    out: list[Path] = []
    for d in dirs:
        if d == root:
            try:
                subs = sorted(p for p in root.iterdir()
                              if p.is_dir() and p.name != ZEEK_ARCHIVE_DIR)
            except OSError:
                subs = []
            out.extend(sub for sub in subs if sub not in out and sub not in dirs)
        if d not in out:
            out.append(d)
    return tuple(out)


def assess_zeek_logs(dirs=ZEEK_LOG_DIRS, logs=(ZEEK_NOTICE_LOG,
                                               ZEEK_WEIRD_LOG,
                                               ZEEK_CONN_LOG)) -> dict:
    """All distinct Zeek log directories to read, and why not when none exist.

    The three failure states are kept DISTINCT because they call for three
    different things from the operator, and collapsing them into "no Zeek
    logs" is how a permissions bug gets mistaken for a quiet network:

      absent     — no candidate directory exists. Zeek has not been run.
      unreadable — a directory exists but this reader cannot read it. THIS IS
                   THE DANGEROUS ONE: Zeek may be detecting plenty and we are
                   blind to all of it. Reported at warning, repeatedly.
      empty      — readable, but holds none of the logs we consume.
      ok         — readable and holding at least one log.
    """
    considered: list[str] = []
    unreadable: list[str] = []
    empty: list[str] = []
    sources: list[dict] = []
    seen: set[Path] = set()
    for d in expand_zeek_log_dirs(dirs):
        d = Path(d)
        considered.append(str(d))
        if not d.is_dir():
            continue
        if not os.access(d, os.R_OK | os.X_OK):
            unreadable.append(str(d))
            continue
        present = [name for name in logs if (d / name).is_file()]
        if not present:
            empty.append(str(d))
            continue
        # `current` may alias an instance; never attach twice to the same source.
        resolved = d.resolve()
        if resolved not in seen:
            seen.add(resolved)
            sources.append({"dir": str(d), "logs": present})
    if sources:
        return {"state": "ok", "dir": sources[0]["dir"],
                "logs": sorted({name for source in sources for name in source["logs"]}),
                "sources": sources, "considered": considered, "unreadable": unreadable}
    if unreadable:
        return {"state": "unreadable", "dir": unreadable[0], "logs": [],
                "considered": considered, "unreadable": unreadable}
    if empty:
        return {"state": "empty", "dir": empty[0], "logs": [],
                "considered": considered, "unreadable": []}
    return {"state": "absent", "dir": "", "logs": [],
            "considered": considered, "unreadable": []}


def zeek_fields_from_header(line: str) -> list[str] | None:
    """Column names from a Zeek TSV `#fields` header line, else None."""
    if not line.startswith("#fields"):
        return None
    parts = line.rstrip("\n").split("\t")
    return [p for p in parts[1:] if p] or None


def zeek_fields_from_file(path, max_header_lines: int = 12) -> list[str] | None:
    """Prime the column list by reading a Zeek log's header.

    Needed because a tailer starts at EOF: without this, a TSV log that was
    already open when we attached has no column names and every row is
    unparseable. Re-read on every (re)open, so log rotation cannot leave us
    decoding new rows with a stale header.
    """
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for _ in range(max_header_lines):
                line = fh.readline()
                if not line:
                    break
                fields = zeek_fields_from_header(line)
                if fields:
                    return fields
                if not line.startswith("#"):
                    break
    except OSError:
        return None
    return None


def zeek_record(line: str, fields: list[str] | None) -> dict | None:
    """One Zeek log line -> dict, for both the TSV and JSON log formats.

    Zeek writes TSV by default and JSON when LogAscii::use_json is set, and
    which one a given deck produces depends on local policy this reader does
    not control. Handling only TSV would mean a JSON-configured Zeek is
    ingested as zero events — silent non-detection again, this time caused by
    a config file nobody remembered.

    Zeek's unset marker "-" and empty marker "(empty)" become None, so callers
    test for a value rather than for a sentinel string.
    """
    line = (line or "").strip()
    if not line or line.startswith("#"):
        return None
    if line.startswith("{"):
        try:
            rec = json.loads(line)
        except ValueError:
            return None
        if not isinstance(rec, dict):
            return None
        return {k: (None if v in ("-", "(empty)") else v)
                for k, v in rec.items()}
    if not fields:
        return None
    parts = line.split("\t")
    if len(parts) < len(fields):
        parts += [None] * (len(fields) - len(parts))
    out: dict = {}
    for name, value in zip(fields, parts):
        out[name] = None if value in ("-", "(empty)", "", None) else value
    return out
