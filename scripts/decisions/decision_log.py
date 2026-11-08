#!/usr/bin/env python3
"""Decision Log generator and checker: inline ``@decision`` blocks are the authority.

# @decision DEC-PHASE13-045
# @title Inline `@decision` blocks are the authority for the Decision Log from
#   Phase 12 onward; MASTER_PLAN.md's table for those phases is generated from
#   them (`make decision-log`) and a unit test fails when the two drift
# @status accepted
# @date 2026-11-06
# @category PROCESS
# @rationale Issue #97: MASTER_PLAN.md's Decision Log held no DEC-PHASE12 rows
#   while 140+ Phase 12 ids lived only as inline blocks, and Phase 13 was
#   recorded in both places by hand. Two authorities for one fact drift; the
#   documented entry point (docs/release-process.md) pointed at the empty one.
#   Option A from the issue is taken: the block next to the code it justifies
#   is where a decision is written once, and the table is a derived surface
#   that this module regenerates into a fenced region of MASTER_PLAN.md
#   (`<!-- decision-log:generated start/end -->`). `--check` enforces that
#   every DEC-PHASE12+ id has exactly one full block (@title, @status,
#   @rationale) and that every id mentioned anywhere in the tree resolves to a
#   block; tests/unit/test_decision_log.sh asserts the committed region equals
#   the generator's output byte for byte, so a block added on any branch shows
#   up in the table at the next `make decision-log` with no code change.
#   Phases 1-11 (and the DEC-MESH/MATRIX/FORENSIC/SEC families) stay as the
#   hand-written historical record below the generated region: their inline
#   blocks predate the one-block-per-id rule and were never held to it.
#   DEC-PHASE13-000 has no code site (it records the owner's /decide session),
#   so it stays a hand-written row above the region. Option B (drop the table,
#   grep for blocks) was rejected because the table is the one place a reader
#   scans decisions in order, and the generator gives the uniqueness lint B
#   would have needed anyway.

House format of a block (the comment token varies by language; ``#``, ``//``,
``--``, ``##!``, ``*`` inside ``/* */``, ``<!-- -->`` and Markdown ``**@tag**``
are all recognised)::

    # @decision DEC-PHASEnn-NNN
    # @title The QEMU gate runs on a pinned runner image (ubuntu-24.04), not
    #   ubuntu-latest
    # @status accepted
    # @rationale On 2026-11-02 GitHub moved ubuntu-latest ...
    #   (continuation lines carry the comment token and extra indentation;
    #   a blank comment line is a paragraph break, not the end of the block)

Optional tags: ``@date YYYY-MM-DD`` (otherwise the git author date of the
commit that introduced the ``@decision`` line), ``@category NAME`` (otherwise
derived from the file path, see CATEGORY_BY_PATH), ``@supersedes``,
``@context`` and anything else are kept and reported by ``--inventory``.

A ``@decision ID`` line with none of @title/@status/@rationale is a
*reference*: it marks another implementation site of a decision whose full
block lives elsewhere. References are allowed; an id with only references and
no full block is an error. A block with some but not all of the three tags is
malformed. An id with more than one full block is an error: exactly one site
is the authority, the others must be references.

Usage::

    decision_log.py --check [--since PHASE12]        # exit 1 on any problem
    decision_log.py --table PHASE12 PHASE13           # emit the table
    decision_log.py --since PHASE12                   # same, every phase >= 12
    decision_log.py --write [--since PHASE12]         # rewrite MASTER_PLAN.md
    decision_log.py --inventory                       # tag/prefix survey
    decision_log.py --dump [--since PHASE12]          # one line per block

stdlib only; Python 3.11+.
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# What is scanned
# ---------------------------------------------------------------------------

# The whole tree is walked (scripts/, iso/, tests/, .github/, docs/, docker/,
# tools/, archive/, Makefile, root *.yml, CHANGELOG.md, MASTER_PLAN.md ...)
# except the directories below: blocks turned up in docker/ and tools/ too,
# and a decision belongs wherever the code it justifies is.
SKIP_DIR_NAMES = {".git", "__pycache__", "node_modules", ".pytest_cache", "tmp",
                  "output", "screenshots", ".claude"}
# This tool's own tests carry fixture blocks and fixture ids; they are not decisions.
SKIP_FILES = {"tests/unit/test_decision_log.sh", "tests/unit/test_decision_log.py"}
# Vendored or binary payloads under iso/ are large and never carry decisions.
SKIP_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".gif", ".ico", ".woff", ".woff2", ".ttf", ".otf",
    ".pdf", ".zip", ".gz", ".xz", ".bz2", ".tar", ".deb", ".iso", ".img",
    ".bin", ".so", ".o", ".pyc", ".db", ".sqlite", ".mp3", ".ogg", ".wav",
    ".mp4", ".webm", ".glb", ".ktx2", ".czml",
}
MAX_FILE_BYTES = 4 * 1024 * 1024

MASTER_PLAN = "MASTER_PLAN.md"
REGION_START = "<!-- decision-log:generated start"
REGION_START_LINE = (
    "<!-- decision-log:generated start "
    "(scripts/decisions/decision_log.py --since PHASE12; do not hand-edit) -->"
)
REGION_END_LINE = "<!-- decision-log:generated end -->"
TABLE_HEADER = ("| ID | Date | Decision | Rationale |",
                "|----|------|----------|-----------|")

# ---------------------------------------------------------------------------
# Category by path. The first matching prefix wins; order matters
# (scripts/release before .github so release.yml is RELEASE, not CI).
# A block's own `@category` tag overrides this table.
# ---------------------------------------------------------------------------
CATEGORY_BY_PATH: tuple[tuple[str, str], ...] = (
    ("scripts/awareness", "DETECTION"),
    ("scripts/release", "RELEASE"),
    (".github/workflows/release.yml", "RELEASE"),
    (".github", "CI"),
    ("scripts/cockpit", "COCKPIT"),
    ("scripts/control_center", "COCKPIT"),
    ("scripts/healing", "HEALING"),
    ("scripts/rain", "RAIN"),
    ("scripts/logquery", "LOGQUERY"),
    ("scripts/osint", "OSINT"),
    ("scripts/pivotglass", "PIVOTGLASS"),
    ("scripts/mesh", "MESH"),
    ("scripts/security", "SECURITY"),
    ("scripts/nebula", "NEBULA"),
    ("scripts/music", "MUSIC"),
    ("scripts/nucleotide", "OSINT"),
    ("scripts/orionx-imager", "IMAGER"),
    ("scripts/setup-matrix.sh", "COMMS"),
    ("scripts/orionx-diag", "DIAG"),
    ("scripts/toggle-theme.sh", "DESKTOP"),
    ("scripts/set-wallpaper.sh", "DESKTOP"),
    ("scripts/build-iso.sh", "BUILD"),
    ("scripts/qemu-boot-test.sh", "CI"),
    ("iso/auto", "BUILD"),
    ("iso/config/hooks", "BUILD"),
    ("iso/config/package-lists", "PACKAGES"),
    ("iso/config/includes.chroot/etc/apparmor.d", "SECURITY"),
    ("iso/config/includes.chroot/etc/nftables.conf", "SECURITY"),
    ("iso/config/includes.chroot/usr/lib/orionx/orionx-apparmor-load", "SECURITY"),
    ("iso/config/includes.chroot/opt/orionx/optional", "INSTALLERS"),
    ("iso/config/includes.chroot/usr/share/orionx/systemd", "BOOT"),
    ("iso/config/includes.chroot/usr/share/icons", "DESKTOP"),
    ("iso/config/includes.chroot/usr/share/themes", "DESKTOP"),
    ("iso/config/includes.chroot/usr/share/desktop-directories", "DESKTOP"),
    ("iso", "ISO"),
    ("tools/guided-demo", "DOCS"),
    ("tools/samples", "SAMPLES"),
    ("tests", "TEST"),
    ("docs", "DOCS"),
    ("Makefile", "BUILD"),
)
DEFAULT_CATEGORY = "MISC"

ID_RE = re.compile(r"DEC-([A-Z]+)(\d*)-(\d{3})(?!\d)")
PHASE_ID_RE = re.compile(r"^DEC-PHASE(\d+)-(\d{3})$")
# A line that opens a block. The comment token is optional so that Markdown
# `**@decision ...**` and plain-text blocks parse too.
START_RE = re.compile(
    r"^(?P<indent>[ \t]*)(?P<tok>##!|#+|//+|/\*+|\*\*|\*|<!--|--)?[ \t]*"
    r"\**@decision[ \t]+(?P<id>DEC-[A-Z0-9]+-\d{3})(?P<rest>.*)$"
)
TAG_RE = re.compile(r"^\**@(?P<tag>[a-z][a-z0-9_-]*)\**(?:[ \t]+(?P<val>.*))?$")
DIVIDER_RE = re.compile(r"^[-=#*_ \t]{3,}$")
REQUIRED_TAGS = ("title", "status", "rationale")


@dataclass
class Block:
    id: str
    path: str                 # repo-relative, posix
    line: int                 # 1-based line of the @decision tag
    token: str                # comment token seen on the @decision line
    tags: dict[str, str] = field(default_factory=dict)
    tag_order: list[str] = field(default_factory=list)
    prose: bool = False       # untagged text followed @decision (reference style)
    end: int = 0              # 1-based last line of the block

    @property
    def is_full(self) -> bool:
        return all(t in self.tags for t in REQUIRED_TAGS)

    @property
    def is_reference(self) -> bool:
        return not any(t in self.tags for t in REQUIRED_TAGS)

    @property
    def missing(self) -> list[str]:
        return [t for t in REQUIRED_TAGS if t not in self.tags]

    @property
    def where(self) -> str:
        return f"{self.path}:{self.line}"


def phase_of(dec_id: str) -> int | None:
    m = PHASE_ID_RE.match(dec_id)
    return int(m.group(1)) if m else None


def sort_key(dec_id: str) -> tuple:
    m = ID_RE.fullmatch(dec_id)
    if not m:
        return (9, dec_id, 0)
    fam, num, seq = m.groups()
    return (0 if fam == "PHASE" else 1, fam, int(num or 0), int(seq))


# ---------------------------------------------------------------------------
# File walk
# ---------------------------------------------------------------------------

def iter_files(root: Path):
    seen: set[Path] = set()

    def want(p: Path) -> bool:
        if p in seen or p.is_symlink() or not p.is_file():
            return False
        if p.suffix.lower() in SKIP_SUFFIXES or p.relative_to(root).as_posix() in SKIP_FILES:
            return False
        try:
            if p.stat().st_size > MAX_FILE_BYTES:
                return False
        except OSError:
            return False
        seen.add(p)
        return True

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(x for x in dirnames if x not in SKIP_DIR_NAMES)
        for fn in sorted(filenames):
            p = Path(dirpath) / fn
            if want(p):
                yield p


def read_text(p: Path) -> str | None:
    try:
        data = p.read_bytes()
    except OSError:
        return None
    if b"\0" in data[:8192]:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("latin-1")


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

def _strip_token(line: str, tok: str) -> tuple[str | None, bool]:
    """Return ``(body, last)`` for a line inside a block opened with ``tok``:
    the comment body (None when the line is not part of that comment) and
    whether the comment closes on this line (``*/`` or ``-->``)."""
    s = line.lstrip(" \t")
    if tok in ("/*", "*", "/**"):
        # inside a /* */ block: lines start with `*`, the closing `*/` ends it
        if s.startswith("*/"):
            return None, True
        if s.startswith("*"):
            body = s[1:]
            if "*/" in body:
                return body.split("*/", 1)[0], True
            return body, False
        return None, True
    if tok == "<!--":
        if "-->" in s:
            return s.split("-->", 1)[0], True
        return s, False
    if tok == "**":
        return (s if s.startswith("**@") else None), False
    if tok == "":
        # plain text: a line that starts with @tag or is indented continuation
        if s.startswith("@") or (line[:1] in (" ", "\t") and s):
            return s, False
        return None, True
    # line comments: `#`, `##!`, `//`, `--` (any run of the first char)
    if tok.startswith("##!"):
        return (s[3:] if s.startswith("##!") else None), False
    ch = tok[0]
    if s.startswith(ch):
        return s.lstrip(ch), False
    return None, True


def parse_text(text: str, path: str) -> list[Block]:
    """Parse every @decision block in ``text``. ``path`` is for reporting."""
    lines = text.splitlines()
    blocks: list[Block] = []
    i = 0
    n = len(lines)
    while i < n:
        m = START_RE.match(lines[i])
        if not m:
            i += 1
            continue
        tok = (m.group("tok") or "").strip()
        if tok.startswith("/*"):
            tok = "/*"
        blk = Block(id=m.group("id"), path=path, line=i + 1, token=tok or "(none)")
        rest = m.group("rest").strip().rstrip("*").strip()
        if tok == "<!--" and rest.endswith("-->"):
            rest = rest[:-3].strip()
            blk.end = i + 1
            blocks.append(blk)          # one-line HTML reference
            i += 1
            continue
        if rest:
            blk.tags.setdefault("_rest", rest)
        cur: str | None = None
        j = i + 1
        while j < n:
            raw = lines[j]
            if START_RE.match(raw):
                break
            body, last = _strip_token(raw, "" if tok == "" else tok)
            if body is None:
                break
            body_s = body.strip()
            if DIVIDER_RE.match(body_s):
                j += 1
                break
            if body_s == "":
                if cur is not None:
                    blk.tags[cur] += "\n"
            else:
                tm = TAG_RE.match(body_s)
                if tm:
                    cur = tm.group("tag")
                    val = (tm.group("val") or "").strip().rstrip("*").strip()
                    if cur in blk.tags:
                        blk.tags[cur] += "\n" + val
                    else:
                        blk.tags[cur] = val
                        blk.tag_order.append(cur)
                elif cur is not None:
                    blk.tags[cur] = blk.tags[cur].rstrip("\n") + (
                        "\n" if blk.tags[cur].endswith("\n") else " ") + body_s
                else:
                    blk.prose = True
            j += 1
            if last:
                break
        for k, v in list(blk.tags.items()):
            blk.tags[k] = v.strip()
        blk.end = max(j, i + 1)
        blocks.append(blk)
        i = max(j, i + 1)
    return blocks


def one_line(s: str) -> str:
    """Collapse a multi-paragraph tag value to one table cell."""
    s = s.replace("|", "\\|")
    return re.sub(r"\s+", " ", s).strip()


# ---------------------------------------------------------------------------
# Repository scan
# ---------------------------------------------------------------------------

@dataclass
class Scan:
    root: Path
    blocks: list[Block]
    mentions: dict[str, list[str]]   # id -> file:line of textual mentions
    files_scanned: int

    def by_id(self) -> dict[str, list[Block]]:
        out: dict[str, list[Block]] = {}
        for b in self.blocks:
            out.setdefault(b.id, []).append(b)
        return out


def scan_repo(root: Path) -> Scan:
    blocks: list[Block] = []
    mentions: dict[str, list[str]] = {}
    count = 0
    for p in iter_files(root):
        text = read_text(p)
        if text is None:
            continue
        count += 1
        rel = p.relative_to(root).as_posix()
        if "@decision" in text:
            blocks.extend(parse_text(text, rel))
        if "DEC-" in text:
            for ln, line in enumerate(text.splitlines(), 1):
                for m in ID_RE.finditer(line):
                    mentions.setdefault(m.group(0), []).append(f"{rel}:{ln}")
    return Scan(root=root, blocks=blocks, mentions=mentions, files_scanned=count)


# ---------------------------------------------------------------------------
# Phase selection
# ---------------------------------------------------------------------------

def parse_phase(name: str) -> int:
    m = re.fullmatch(r"(?:DEC-)?PHASE(\d+)", name.upper())
    if not m:
        raise argparse.ArgumentTypeError(f"not a phase name: {name!r} (expected e.g. PHASE12)")
    return int(m.group(1))


def selected(dec_id: str, phases: set[int] | None, since: int | None) -> bool:
    ph = phase_of(dec_id)
    if ph is None:
        return False
    if phases is not None and ph in phases:
        return True
    return since is not None and ph >= since


# ---------------------------------------------------------------------------
# Dates via git blame
# ---------------------------------------------------------------------------

_blame_cache: dict[str, dict[int, str]] = {}


def blame_dates(root: Path, rel: str) -> dict[int, str]:
    """line number -> YYYY-MM-DD author date (author's own timezone).
    Uncommitted lines map to today's date."""
    if rel in _blame_cache:
        return _blame_cache[rel]
    out: dict[int, str] = {}
    try:
        res = subprocess.run(
            ["git", "-C", str(root), "blame", "--porcelain", "--", rel],
            capture_output=True, text=True, check=False, encoding="utf-8", errors="replace",
        )
        porcelain = res.stdout if res.returncode == 0 else ""
    except OSError:
        porcelain = ""
    today = _today()
    sha_time: dict[str, tuple[int, str]] = {}
    cur_sha = None
    cur_line = None
    for line in porcelain.splitlines():
        m = re.match(r"^([0-9a-f]{40}) (\d+) (\d+)(?: (\d+))?$", line)
        if m:
            cur_sha, cur_line = m.group(1), int(m.group(3))
            if cur_sha in sha_time:
                out[cur_line] = _fmt(*sha_time[cur_sha], today)
            continue
        if cur_sha is None:
            continue
        if line.startswith("author-time "):
            sha_time.setdefault(cur_sha, (int(line.split()[1]), "+0000"))
        elif line.startswith("author-tz "):
            t, _ = sha_time.get(cur_sha, (0, "+0000"))
            sha_time[cur_sha] = (t, line.split()[1])
        elif line.startswith("\t") and cur_line is not None:
            out[cur_line] = _fmt(*sha_time.get(cur_sha, (0, "+0000")), today) \
                if cur_sha in sha_time else today
            cur_line = None
    _blame_cache[rel] = out
    return out


def _fmt(epoch: int, tz: str, today: str) -> str:
    if epoch == 0 or not re.fullmatch(r"[+-]\d{4}", tz):
        return today
    sign = 1 if tz[0] == "+" else -1
    off = sign * (int(tz[1:3]) * 3600 + int(tz[3:5]) * 60)
    return dt.datetime.fromtimestamp(epoch, dt.timezone(dt.timedelta(seconds=off))).date().isoformat()


def block_date(root: Path, b: Block) -> str:
    d = b.tags.get("date", "").strip()
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", d):
        return d
    return blame_dates(root, b.path).get(b.line, _today())


def _today() -> str:
    """Date for lines git has not committed yet (the author date they will get)."""
    return dt.datetime.now(tz=dt.timezone.utc).astimezone().date().isoformat()


def shallow_repo(root: Path) -> bool:
    """True when `root` is a shallow clone. Blame in a shallow clone attributes
    every line to the boundary commit, so row dates would all read as that
    commit's date (CI's default depth-1 checkout produced 113 wrong dates on
    2026-11-07). Rows must never be emitted from one."""
    try:
        res = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--is-shallow-repository"],
            capture_output=True, text=True, check=False,
        )
    except OSError:
        return False
    return res.returncode == 0 and res.stdout.strip() == "true"


def block_category(b: Block) -> str:
    c = b.tags.get("category", "").strip().strip("[]").upper()
    if c:
        return c
    for prefix, cat in CATEGORY_BY_PATH:
        if b.path == prefix or b.path.startswith(prefix.rstrip("/") + "/") or b.path.startswith(prefix):
            return cat
    return DEFAULT_CATEGORY


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

def hand_written_ids(root: Path) -> set[str]:
    """Ids of the rows MASTER_PLAN's Decision Log keeps by hand OUTSIDE the
    generated region (decisions with no code site, e.g. DEC-PHASE13-000).
    Such an id needs no block; an id with both a row there and a block is an
    error (the generated table takes over)."""
    mp = root / MASTER_PLAN
    if not mp.is_file():
        return set()
    text = mp.read_text(encoding="utf-8")
    m = re.search(r"^## Decision Log[ \t]*$", text, re.M)
    if not m:
        return set()
    nxt = re.compile(r"^## ", re.M).search(text, m.end())
    section = text[m.start():nxt.start() if nxt else None]
    try:
        a, b = region_bounds(section)
        section = section[:a] + section[b:]
    except ValueError:
        pass
    return {m.group(1) for m in re.finditer(r"^\| (DEC-[A-Z0-9]+-\d{3}) \|", section, re.M)}


def canonical_block(blocks: list[Block]) -> Block | None:
    """The one full block that is the authority for an id: the @canonical one
    when several are full, else the only full one."""
    full = [b for b in blocks if b.is_full]
    if not full:
        return None
    canon = [b for b in full if "canonical" in b.tags]
    return canon[0] if len(canon) == 1 else (full[0] if len(full) == 1 else None)


def check(scan: Scan, phases: set[int] | None, since: int | None) -> list[str]:
    """Return problem lines (empty means clean) for the selected phases."""
    problems: list[str] = []
    by_id = scan.by_id()
    hand_written = {i for i in hand_written_ids(scan.root) if selected(i, phases, since)}
    for dec_id in sorted(by_id, key=sort_key):
        if not selected(dec_id, phases, since):
            continue
        bl = by_id[dec_id]
        full = [b for b in bl if b.is_full]
        partial = [b for b in bl if not b.is_full and not b.is_reference]
        for b in partial:
            problems.append(f"{b.where}: {dec_id} block is missing @{', @'.join(b.missing)}")
        if not full:
            refs = ", ".join(b.where for b in bl if b.is_reference)
            problems.append(
                f"{bl[0].where}: {dec_id} has no full block (@title/@status/@rationale)"
                + (f"; references only at {refs}" if refs else ""))
        elif len(full) > 1:
            canon = [b for b in full if "canonical" in b.tags]
            if len(canon) != 1:
                sites = ", ".join(b.where for b in full)
                problems.append(
                    f"{full[0].where}: {dec_id} has {len(full)} full blocks and "
                    f"{len(canon)} marked @canonical (exactly one must be): {sites}")
        if dec_id in hand_written and full:
            problems.append(f"{MASTER_PLAN}: {dec_id} has a hand-written row AND a block at "
                            f"{full[0].where}; delete the row, the generated table takes over")
        for b in full:
            d = b.tags.get("date")
            if d is not None and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", d.strip()):
                problems.append(f"{b.where}: {dec_id} @date {d!r} is not YYYY-MM-DD")
            if not b.tags["title"].strip():
                problems.append(f"{b.where}: {dec_id} @title is empty")
            if not b.tags["rationale"].strip():
                problems.append(f"{b.where}: {dec_id} @rationale is empty")
    # ids mentioned anywhere (code, docs, MASTER_PLAN, CHANGELOG) that have no block
    for dec_id in sorted(scan.mentions, key=sort_key):
        if not selected(dec_id, phases, since) or dec_id in by_id or dec_id in hand_written:
            continue
        sites = scan.mentions[dec_id]
        problems.append(f"{sites[0]}: {dec_id} is referenced ({len(sites)} place(s)) "
                        f"but has no @decision block and no hand-written row")
    return problems


# ---------------------------------------------------------------------------
# Table
# ---------------------------------------------------------------------------

def rows(scan: Scan, phases: set[int] | None, since: int | None) -> list[str]:
    by_id = scan.by_id()
    out: list[str] = []
    for dec_id in sorted(by_id, key=sort_key):
        if not selected(dec_id, phases, since):
            continue
        b = canonical_block(by_id[dec_id])
        if b is None:
            continue
        title = one_line(b.tags["title"])
        status = b.tags.get("status", "").strip()
        if status and status.lower() != "accepted":
            title += f" (status: {one_line(status)})"
        out.append(f"| {dec_id} | {block_date(scan.root, b)} | [{block_category(b)}] {title} "
                   f"| {one_line(b.tags['rationale'])} |")
    return out


def table(scan: Scan, phases: set[int] | None, since: int | None) -> str:
    return "\n".join([*TABLE_HEADER, *rows(scan, phases, since)]) + "\n"


def region_bounds(text: str) -> tuple[int, int]:
    """(start_idx, end_idx) of the generated region's content in ``text``:
    the slice between the end of the start-marker line and the start of the
    end-marker line. Raises ValueError when the markers are absent."""
    s = text.find(REGION_START)
    if s < 0:
        raise ValueError(f"{MASTER_PLAN} has no '{REGION_START} ...' marker")
    s_eol = text.find("\n", s)
    e = text.find(REGION_END_LINE, s_eol)
    if s_eol < 0 or e < 0:
        raise ValueError(f"{MASTER_PLAN} has no '{REGION_END_LINE}' marker after the start marker")
    return s_eol + 1, e


def read_region(text: str) -> str:
    a, b = region_bounds(text)
    return text[a:b]


def write_region(root: Path, new_table: str) -> bool:
    """Replace the generated region; return True when the file changed."""
    mp = root / MASTER_PLAN
    text = mp.read_text(encoding="utf-8")
    a, b = region_bounds(text)
    updated = text[:a] + new_table + text[b:]
    if updated == text:
        return False
    mp.write_text(updated, encoding="utf-8")
    return True


# ---------------------------------------------------------------------------
# Inventory / dump
# ---------------------------------------------------------------------------

def inventory(scan: Scan) -> str:
    tags: dict[str, int] = {}
    toks: dict[str, int] = {}
    phases: dict[str, int] = {}
    for b in scan.blocks:
        toks[b.token] = toks.get(b.token, 0) + 1
        for t in b.tags:
            tags[t] = tags.get(t, 0) + 1
        fam = re.sub(r"-\d{3}$", "", b.id)
        phases[fam] = phases.get(fam, 0) + 1
    lines = [f"files scanned: {scan.files_scanned}", f"@decision lines: {len(scan.blocks)}",
             f"full blocks: {sum(b.is_full for b in scan.blocks)}",
             f"references (bare @decision): {sum(b.is_reference for b in scan.blocks)}",
             f"partial (malformed): {sum((not b.is_full and not b.is_reference) for b in scan.blocks)}",
             "", "tags:"]
    lines += [f"  @{t}: {c}" for t, c in sorted(tags.items(), key=lambda x: -x[1])]
    lines += ["", "comment tokens on the @decision line:"]
    lines += [f"  {t!r}: {c}" for t, c in sorted(toks.items(), key=lambda x: -x[1])]
    lines += ["", "ids per family:"]
    lines += [f"  {f}: {c}" for f, c in sorted(phases.items())]
    return "\n".join(lines) + "\n"


def dump(scan: Scan, phases: set[int] | None, since: int | None) -> str:
    out = []
    for b in sorted(scan.blocks, key=lambda b: (sort_key(b.id), b.path, b.line)):
        if phases is None and since is None or selected(b.id, phases, since):
            kind = "full" if b.is_full else ("ref" if b.is_reference else "PARTIAL")
            out.append(f"{b.id}\t{kind}\t{b.where}\t{one_line(b.tags.get('title', ''))[:90]}")
    return "\n".join(out) + ("\n" if out else "")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def find_root(start: Path) -> Path:
    for p in (start, *start.parents):
        if (p / MASTER_PLAN).is_file() and (p / "scripts").is_dir():
            return p
    return start


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    ap.add_argument("--root", type=Path, default=None, help="repository root (default: auto)")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--check", action="store_true", help="validate blocks; exit 1 on any problem")
    g.add_argument("--table", nargs="+", metavar="PHASE", help="emit rows for these phases")
    g.add_argument("--write", action="store_true", help="rewrite the generated region of MASTER_PLAN.md")
    g.add_argument("--inventory", action="store_true", help="survey tags and comment styles")
    g.add_argument("--dump", action="store_true", help="one line per @decision line")
    ap.add_argument("--since", metavar="PHASE", default=None,
                    help="select every phase >= this one (default PHASE12 for --check/--write)")
    args = ap.parse_args(argv)

    root = (args.root or find_root(Path(__file__).resolve().parent)).resolve()
    phases = {parse_phase(p) for p in args.table} if args.table else None
    since = parse_phase(args.since) if args.since else None
    if phases is None and since is None and not (args.inventory or args.dump):
        since = 12

    emits_dates = not (args.check or args.inventory or args.dump)
    if emits_dates and shallow_repo(root):
        print("decision_log: refusing to emit rows from a shallow clone: git blame would date "
              "every row to the boundary commit. Run `git fetch --unshallow` (CI: "
              "actions/checkout with fetch-depth: 0).", file=sys.stderr)
        return 2

    scan = scan_repo(root)

    if args.inventory:
        sys.stdout.write(inventory(scan))
        return 0
    if args.dump:
        sys.stdout.write(dump(scan, phases, since))
        return 0
    if args.check:
        problems = check(scan, phases, since)
        for p in problems:
            print(p)
        if problems:
            print(f"decision_log: {len(problems)} problem(s)", file=sys.stderr)
            return 1
        n = sum(1 for i, bl in scan.by_id().items()
                if selected(i, phases, since) and canonical_block(bl) is not None)
        print(f"decision_log: OK ({n} decisions, {len(scan.blocks)} @decision lines in {scan.files_scanned} files)")
        return 0
    if args.write:
        problems = check(scan, phases, since)
        if problems:
            for p in problems:
                print(p)
            print("decision_log: refusing to write with problems above", file=sys.stderr)
            return 1
        changed = write_region(root, table(scan, phases, since))
        print(f"decision_log: {MASTER_PLAN} generated region "
              f"{'updated' if changed else 'already current'}")
        return 0
    sys.stdout.write(table(scan, phases, since))
    return 0


if __name__ == "__main__":
    sys.exit(main())
