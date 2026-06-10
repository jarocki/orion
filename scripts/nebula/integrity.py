"""
Nebula AI — Model Integrity Verification.

Invoked at boot by nebula-integrity-check.service (Type=oneshot).  Verifies
every GGUF file in the models directory against the MANIFEST.sha256 generated
by stage_nebula_model() in scripts/build-iso.sh.

Exit codes:
    0  — all files verified OK; status file written with OK state
    1  — verification failed (hash mismatch, missing file, or bad manifest);
         status file written with FAIL state; error logged to INTEGRITY_LOG
    2  — usage error (bad arguments)

Status file format (written to --status-file, default /run/orionx/nebula-integrity.status):
    NEBULA_INTEGRITY=OK|FAIL
    NEBULA_INTEGRITY_DETAIL=<human-readable message>
    NEBULA_INTEGRITY_TS=<ISO-8601 timestamp>

Can be invoked as:
    python3 /opt/orionx/scripts/nebula/integrity.py
    python3 -m nebula.integrity           (from the scripts/ directory)

@decision DEC-PHASE10-009
@title integrity.py: single authority for boot-time model integrity verification
@status accepted
@rationale SHA-256 chain: nebula-model-manifest.json (build source) ->
  stage_nebula_model() downloads + verifies + generates MANIFEST.sha256 ->
  THIS MODULE reads MANIFEST.sha256 at boot and re-verifies the on-disk GGUF.
  On mismatch the unit exits non-zero, which causes systemd to mark
  nebula-integrity-check.service failed and refuse to start nebula-runtime.service
  (Requires= ordering in the service file).  A tampered model must NEVER run
  silently. The status file is consumed by the Control Center to show a red badge.
  References: DEC-PHASE10-009 (boot gate), DEC-PHASE10-005 (Control Center status).

@decision DEC-PHASE9-019
@title from __future__ import annotations required in all Phase 10 Python modules
@status accepted
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import logging
import os
import sys
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Logging — always goes to stderr so systemd's journal captures it, PLUS to
# the dedicated integrity log file when --log-file is supplied (which the
# service unit does via StandardOutput/StandardError redirect).
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [nebula-integrity] %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
    stream=sys.stderr,
)
logger = logging.getLogger("nebula.integrity")

# ---------------------------------------------------------------------------
# Default paths — can be overridden via CLI args for testing.
# We do NOT import from helpers.paths here when invoked as __main__ from an
# absolute path (the package may not be on sys.path in the systemd context).
# The defaults mirror helpers/paths.py literals exactly.
# ---------------------------------------------------------------------------
_DEFAULT_MODELS_DIR = Path("/opt/orionx/nebula/models")
_DEFAULT_MANIFEST = _DEFAULT_MODELS_DIR / "MANIFEST.sha256"
_DEFAULT_STATUS_FILE = Path("/run/orionx/nebula-integrity.status")

_BLOCK_SIZE = 65536  # 64 KiB read chunks for large GGUF files


def _sha256_file(path: Path) -> str:
    """Return the lowercase hex SHA-256 digest of the file at *path*.

    Reads the file in chunks to avoid loading the full 4.4 GB GGUF into RAM.

    Raises:
        OSError: if the file cannot be opened or read.
    """
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(_BLOCK_SIZE), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_manifest(manifest_path: Path) -> dict[str, str]:
    """Parse a sha256sum-compatible MANIFEST.sha256 file.

    Format of each line: ``<hex_sha256>  <filename>``  (two spaces, as written
    by ``sha256sum``).

    Returns:
        Dict mapping filename -> expected_sha256 (lowercase hex).

    Raises:
        FileNotFoundError: if manifest_path does not exist.
        ValueError: if any line is not in the expected ``<hash>  <name>`` form.
    """
    if not manifest_path.exists():
        raise FileNotFoundError(
            f"MANIFEST.sha256 not found at {manifest_path}. "
            "The model may not have been staged correctly by stage_nebula_model()."
        )

    entries: dict[str, str] = {}
    for lineno, raw in enumerate(manifest_path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        # sha256sum format: exactly two spaces between hash and name
        parts = line.split("  ", 1)
        if len(parts) != 2:
            raise ValueError(
                f"MANIFEST.sha256 line {lineno} is malformed "
                f"(expected '<hash>  <filename>', got: {line!r})"
            )
        hex_hash, filename = parts
        if len(hex_hash) != 64 or not all(c in "0123456789abcdef" for c in hex_hash):
            raise ValueError(
                f"MANIFEST.sha256 line {lineno}: hash is not a 64-char lowercase hex "
                f"string: {hex_hash!r}"
            )
        entries[filename.strip()] = hex_hash
    return entries


def write_status(
    status_file: Path,
    ok: bool,
    detail: str,
) -> None:
    """Write the machine-readable integrity status file.

    The Control Center reads this file to show the green/red Nebula badge.
    The file is written atomically (write to .tmp then rename) so the Control
    Center never reads a half-written status.

    Format::

        NEBULA_INTEGRITY=OK
        NEBULA_INTEGRITY_DETAIL=all 1 model file(s) verified OK
        NEBULA_INTEGRITY_TS=2026-06-09T10:30:00
    """
    ts = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S")
    state = "OK" if ok else "FAIL"
    content = (
        f"NEBULA_INTEGRITY={state}\n"
        f"NEBULA_INTEGRITY_DETAIL={detail}\n"
        f"NEBULA_INTEGRITY_TS={ts}\n"
    )
    # Ensure the parent directory exists (tmpfs; created by service ExecStartPre)
    try:
        status_file.parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        logger.warning("Could not create status dir %s: %s", status_file.parent, exc)

    tmp_path = status_file.with_suffix(".tmp")
    try:
        tmp_path.write_text(content, encoding="utf-8")
        tmp_path.rename(status_file)
    except OSError as exc:
        logger.warning("Could not write status file %s: %s", status_file, exc)


def verify_manifest(
    models_dir: Path,
    manifest_path: Path,
    *,
    test_models_dir: Optional[Path] = None,
) -> bool:
    """Verify all files listed in *manifest_path* exist under *models_dir*
    and their SHA-256 digests match.

    This is the primary callable for external test code.

    Args:
        models_dir: Directory containing the GGUF model files.
        manifest_path: Path to the MANIFEST.sha256 file.
        test_models_dir: When set, restricts verification to files under this
            path (used by unit tests that pass TEST_NEBULA_MODELS_DIR).

    Returns:
        True if all files pass; False on any mismatch or read error (does NOT
        raise — failures are logged to stderr for the systemd journal).

    Raises:
        FileNotFoundError: when MANIFEST.sha256 is absent (loud failure per
            DEC-PHASE10-009 — a missing manifest means staging failed).
    """
    # Determine which base directory to use for resolving model filenames.
    effective_dir = test_models_dir if test_models_dir is not None else models_dir

    try:
        entries = parse_manifest(manifest_path)
    except FileNotFoundError:
        logger.error(
            "MANIFEST.sha256 missing at %s — model not staged or staging failed.",
            manifest_path,
        )
        raise  # Propagate: missing manifest is a hard error (DEC-PHASE10-009)
    except ValueError as exc:
        logger.error("MANIFEST.sha256 is malformed: %s", exc)
        return False

    if not entries:
        logger.error("MANIFEST.sha256 is empty — no files to verify.")
        return False

    all_ok = True
    for filename, expected_hash in entries.items():
        file_path = effective_dir / filename
        if not file_path.exists():
            logger.error(
                "Model file missing: %s (expected at %s)", filename, file_path
            )
            all_ok = False
            continue

        logger.info("Verifying %s ...", filename)
        try:
            actual_hash = _sha256_file(file_path)
        except OSError as exc:
            logger.error("Cannot read %s: %s", file_path, exc)
            all_ok = False
            continue

        if actual_hash != expected_hash:
            logger.error(
                "INTEGRITY MISMATCH: %s\n  expected: %s\n  got:      %s",
                filename,
                expected_hash,
                actual_hash,
            )
            all_ok = False
        else:
            logger.info("OK: %s  %s", actual_hash, filename)

    return all_ok


# ---------------------------------------------------------------------------
# CLI entrypoint — invoked by nebula-integrity-check.service
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="nebula-integrity",
        description="Verify Nebula AI model integrity at boot (DEC-PHASE10-009).",
    )
    parser.add_argument(
        "--models-dir",
        type=Path,
        default=_DEFAULT_MODELS_DIR,
        help=f"Directory containing GGUF model files (default: {_DEFAULT_MODELS_DIR})",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=_DEFAULT_MANIFEST,
        help=f"Path to MANIFEST.sha256 (default: {_DEFAULT_MANIFEST})",
    )
    parser.add_argument(
        "--status-file",
        type=Path,
        default=_DEFAULT_STATUS_FILE,
        help=f"Status file written for Control Center consumption (default: {_DEFAULT_STATUS_FILE})",
    )
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    """Main entrypoint.  Returns 0 on success, 1 on failure, 2 on usage error."""
    parser = _build_parser()
    args = parser.parse_args(argv)

    # Honour TEST_NEBULA_MODELS_DIR env var (unit-test fixture override)
    test_dir_env = os.environ.get("TEST_NEBULA_MODELS_DIR")
    test_dir: Optional[Path] = Path(test_dir_env) if test_dir_env else None

    logger.info(
        "Starting integrity check: models_dir=%s manifest=%s status_file=%s",
        args.models_dir,
        args.manifest,
        args.status_file,
    )

    try:
        ok = verify_manifest(args.models_dir, args.manifest, test_models_dir=test_dir)
    except FileNotFoundError as exc:
        # Missing manifest = loud failure (DEC-PHASE10-009)
        detail = f"MANIFEST.sha256 missing: {exc}"
        logger.error(detail)
        write_status(args.status_file, ok=False, detail=detail)
        return 1
    except Exception as exc:  # noqa: BLE001
        detail = f"Unexpected error during integrity check: {exc}"
        logger.error(detail)
        write_status(args.status_file, ok=False, detail=detail)
        return 1

    verified_count = 1  # single model in W10-1; future slices may add more
    if ok:
        detail = f"all {verified_count} model file(s) verified OK"
        logger.info("Integrity check PASSED: %s", detail)
        write_status(args.status_file, ok=True, detail=detail)
        return 0
    else:
        detail = "one or more model files failed integrity verification — see logs"
        logger.error("Integrity check FAILED: %s", detail)
        write_status(args.status_file, ok=False, detail=detail)
        return 1


if __name__ == "__main__":
    sys.exit(main())
