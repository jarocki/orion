"""
Nebula AI — ollama model-store consolidation (build time).

Invoked by iso/config/hooks/live/0510-register-nebula-model.hook.chroot right
after `ollama create` has imported the bundled GGUF.  Makes the ollama blob
store the ONE on-disk copy of the model and re-points MANIFEST.sha256 at the
bytes ollama actually loads.

Usage:
    python3 store.py consolidate --models-dir /opt/orionx/nebula/models \
        --source-gguf /opt/orionx/nebula/models/Qwen2.5-3B-Instruct-Q4_K_M.gguf
    python3 store.py consolidate ... --dry-run      # report only, delete nothing

Exit codes:
    0 — store consolidated (or dry-run report printed)
    1 — refused: no manifest, a referenced blob is missing or fails its own
        content hash, or a filesystem error.  NOTHING is deleted on refusal.
    2 — usage error

@decision DEC-PHASE12-016
@title Ship the model once: the ollama blob store is the single copy; integrity binds to the live layer
@status accepted
@rationale DEC-PHASE11-021 kept the source GGUF next to ollama's store on the
  assumption that mksquashfs would deduplicate it against the imported blob.
  Measured on trixie-dev7: `ollama create` RE-SERIALISES the GGUF, so the live
  layer (sha256-fb8a8b68…) differs from the source (sha256-9c9f56a3…) although
  both are 1,929,903,264 bytes; ollama also left the byte-identical first copy
  behind as an orphan blob.  Result: two distinct ~1.8 GB compressed copies in
  the squashfs — ≈3.6 GB of a 4.99 GB ISO, while the whole OS is ≈1.3 GB.
  Fix: after import, (1) parse ollama's manifests, (2) verify every referenced
  blob hashes to its own content-addressed name, (3) delete unreferenced blobs
  and the source GGUF, (4) rewrite MANIFEST.sha256 to list the referenced blobs
  (model layer first).  integrity.py (DEC-PHASE10-009) is unchanged in
  mechanism and now verifies the exact bytes the runtime executes — a stronger
  gate than hashing a file ollama never read.  The provenance chain is intact:
  nebula-model-manifest.json pin → stage_nebula_model() verifies the HF download
  → ollama create → this module verifies the live layer → MANIFEST.sha256 →
  boot verification.  Refuse-and-keep-everything on any doubt: a hard failure
  here fails the build (DEC-PHASE10-007) rather than shipping a store we could
  not verify.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any, Optional

_BLOCK_SIZE = 1 << 20
_BLOB_PREFIX = "sha256-"


class StoreError(RuntimeError):
    """Raised when the store cannot be verified — caller must delete nothing."""


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(_BLOCK_SIZE), b""):
            h.update(chunk)
    return h.hexdigest()


def _digest_hex(digest: str) -> str:
    """'sha256:abc…' -> 'abc…' (ollama manifests use the colon form)."""
    if ":" in digest:
        algo, _, hex_part = digest.partition(":")
        if algo != "sha256":
            raise StoreError(f"unsupported digest algorithm in manifest: {digest!r}")
        return hex_part
    return digest


def referenced_layers(models_dir: Path) -> list[dict[str, Any]]:
    """Return every blob referenced by any ollama manifest under *models_dir*.

    Each entry: {"digest": <hex>, "media_type": str, "size": int, "manifest": str}.
    Model layers (mediaType ending in ".model") are ordered first, largest first,
    so the first MANIFEST.sha256 line is the weights file that status.py sizes.
    """
    manifests_root = models_dir / "manifests"
    files = sorted(p for p in manifests_root.rglob("*") if p.is_file()) if manifests_root.is_dir() else []
    if not files:
        raise StoreError(f"no ollama manifests under {manifests_root} — was `ollama create` run?")

    layers: dict[str, dict[str, Any]] = {}
    for mf in files:
        try:
            doc = json.loads(mf.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise StoreError(f"cannot parse ollama manifest {mf}: {exc}") from exc
        entries = list(doc.get("layers", []))
        if isinstance(doc.get("config"), dict):
            entries.append(doc["config"])
        for entry in entries:
            digest = _digest_hex(str(entry.get("digest", "")))
            if len(digest) != 64:
                raise StoreError(f"malformed digest in {mf}: {entry.get('digest')!r}")
            layers.setdefault(
                digest,
                {
                    "digest": digest,
                    "media_type": str(entry.get("mediaType", "")),
                    "size": int(entry.get("size", 0)),
                    "manifest": str(mf.relative_to(models_dir)),
                },
            )
    if not layers:
        raise StoreError("ollama manifests reference no blobs")

    def _key(layer: dict[str, Any]) -> tuple[int, int]:
        is_model = 0 if layer["media_type"].endswith(".model") else 1
        return (is_model, -layer["size"])

    ordered = sorted(layers.values(), key=_key)
    if not ordered[0]["media_type"].endswith(".model"):
        raise StoreError("no model layer (mediaType *.model) referenced by any manifest")
    return ordered


def blob_path(models_dir: Path, digest: str) -> Path:
    return models_dir / "blobs" / f"{_BLOB_PREFIX}{digest}"


def verify_layers(models_dir: Path, layers: list[dict[str, Any]]) -> None:
    """Every referenced blob must exist, match its declared size, and hash to its name."""
    for layer in layers:
        path = blob_path(models_dir, layer["digest"])
        if not path.is_file():
            raise StoreError(f"referenced blob missing: {path}")
        actual_size = path.stat().st_size
        if layer["size"] and actual_size != layer["size"]:
            raise StoreError(
                f"size mismatch for {path.name}: manifest says {layer['size']}, file is {actual_size}"
            )
        actual = _sha256_file(path)
        if actual != layer["digest"]:
            raise StoreError(
                f"content-address mismatch for {path.name}: file hashes to {actual}"
            )


def orphan_blobs(models_dir: Path, layers: list[dict[str, Any]]) -> list[Path]:
    blobs_dir = models_dir / "blobs"
    if not blobs_dir.is_dir():
        return []
    keep = {layer["digest"] for layer in layers}
    orphans = []
    for p in sorted(blobs_dir.iterdir()):
        if p.is_file() and p.name.startswith(_BLOB_PREFIX) and p.name[len(_BLOB_PREFIX):] not in keep:
            orphans.append(p)
    return orphans


def manifest_text(layers: list[dict[str, Any]]) -> str:
    """sha256sum-compatible lines, model layer first (what integrity.py parses)."""
    lines = [
        "# Nebula model store — generated by scripts/nebula/store.py (DEC-PHASE12-016).",
        "# Each line is an ollama blob; the hash IS the blob's content address.",
    ]
    for layer in layers:
        lines.append(f"{layer['digest']}  blobs/{_BLOB_PREFIX}{layer['digest']}")
    return "\n".join(lines) + "\n"


def consolidate(
    models_dir: Path,
    source_gguf: Optional[Path] = None,
    *,
    dry_run: bool = False,
    verify: bool = True,
) -> dict[str, Any]:
    """Verify the store, then drop orphan blobs + the source GGUF and rewrite MANIFEST.sha256.

    Raises StoreError before touching anything if the store cannot be verified.
    """
    layers = referenced_layers(models_dir)
    if verify:
        verify_layers(models_dir, layers)

    orphans = orphan_blobs(models_dir, layers)
    source = source_gguf if (source_gguf and source_gguf.is_file()) else None
    removed_bytes = sum(p.stat().st_size for p in orphans) + (source.stat().st_size if source else 0)

    report: dict[str, Any] = {
        "models_dir": str(models_dir),
        "dry_run": dry_run,
        "kept": [f"blobs/{_BLOB_PREFIX}{layer['digest']}" for layer in layers],
        "model_layer": layers[0]["digest"],
        "removed_orphans": [str(p.relative_to(models_dir)) for p in orphans],
        "removed_source": str(source) if source else None,
        "removed_bytes": removed_bytes,
    }
    if dry_run:
        return report

    for p in orphans:
        p.unlink()
    if source:
        source.unlink()
    (models_dir / "MANIFEST.sha256").write_text(manifest_text(layers), encoding="utf-8")
    return report


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="nebula-store", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("consolidate", help="verify the ollama store, drop duplicates, rewrite MANIFEST.sha256")
    c.add_argument("--models-dir", type=Path, required=True)
    c.add_argument("--source-gguf", type=Path, default=None, help="imported GGUF to delete after verification")
    c.add_argument("--dry-run", action="store_true", help="report only; delete and write nothing")
    c.add_argument("--no-verify", action="store_true", help="skip blob content hashing (tests only)")
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        report = consolidate(
            args.models_dir, args.source_gguf, dry_run=args.dry_run, verify=not args.no_verify
        )
    except StoreError as exc:
        print(f"nebula-store: REFUSED — {exc} (nothing deleted)", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"nebula-store: filesystem error — {exc}", file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
