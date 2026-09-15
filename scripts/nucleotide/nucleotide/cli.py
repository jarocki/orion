"""Command-line entry point: build the lookup, query it against URLs."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .actor import fingerprint as actor_fingerprint
from .actor import parse_events_jsonl, to_yaml
from .build import build_lookup
from .quality import at_least, match_quality
from .fetch import PROJECTDISCOVERY_REPO, fetch
from .sigma import render_sigma, render_sigma_by_tier
from .signatures import TIERS, render_snort, render_snort_by_tier, render_yara


def _build(args: argparse.Namespace) -> int:
    if args.templates_dir:
        tdir = args.templates_dir
        source = str(tdir.resolve())
    else:
        tdir = fetch(args.repo, args.cache_dir, update=not args.no_fetch)
        source = args.repo
    result = build_lookup(tdir, source_url=source, min_snippet_len=args.min_len)
    args.out.write_text(json.dumps(result, indent=2, sort_keys=True))
    if args.yara_out:
        args.yara_out.write_text(render_yara(result.get("signatures") or {}))
    if args.snort_out:
        args.snort_out.write_text(render_snort(result.get("signatures") or {}))
    if args.snort_out_dir:
        args.snort_out_dir.mkdir(parents=True, exist_ok=True)
        per_tier = render_snort_by_tier(result.get("signatures") or {})
        for tier, text in per_tier.items():
            if text.strip():
                (args.snort_out_dir / f"nuclei-{tier.lower()}.rules").write_text(text)
    if args.sigma_out:
        args.sigma_out.write_text(render_sigma(result.get("signatures") or {}))
    if args.sigma_out_dir:
        args.sigma_out_dir.mkdir(parents=True, exist_ok=True)
        for tier, text in render_sigma_by_tier(result.get("signatures") or {}).items():
            if text.strip():
                (args.sigma_out_dir / f"nuclei-{tier.lower()}.yml").write_text(text)
    md = result["metadata"]
    sigs = result.get("signatures") or {}
    yara_n = len(sigs.get("yara") or {})
    snort_by_tier: dict[str, int] = {t: 0 for t in TIERS}
    for entries in (sigs.get("snort") or {}).values():
        for entry in entries:
            tier = entry.get("tier")
            if tier in snort_by_tier:
                snort_by_tier[tier] += 1
    snort_summary = " ".join(
        f"{t}={snort_by_tier[t]}" for t in TIERS if snort_by_tier[t]
    )
    q = md.get("snippet_quality_counts", {})
    quality_summary = (
        f" quality[strong={q.get('strong',0)} "
        f"medium={q.get('medium',0)} weak={q.get('weak',0)}]"
        if q
        else ""
    )
    print(
        f"Wrote {args.out} | templates={md['template_count']} "
        f"snippets={md['resolved_snippets']} unresolved={md['unresolved_count']} "
        f"yara={yara_n} snort[{snort_summary}]{quality_summary}",
        file=sys.stderr,
    )
    return 0


def _lookup(args: argparse.Namespace) -> int:
    data = json.loads(args.lookup_file.read_text())
    snippet_index: dict[str, str] = data.get("snippet_index", {})
    snippet_items = sorted(snippet_index.items(), key=lambda kv: -len(kv[0]))
    templates: dict[str, dict] = data.get("templates", {})
    quality_map: dict[str, str] = data.get("snippet_quality", {})
    min_quality = getattr(args, "min_quality", "weak")

    chunk_targets: list[tuple[str, str]] = []
    if not args.strict:
        seen_pairs: set[tuple[str, str]] = set()
        for tid, meta in templates.items():
            if meta.get("url_snippet"):
                continue
            for c in meta.get("chunks") or ():
                if len(c) >= args.min_chunk and (c, tid) not in seen_pairs:
                    chunk_targets.append((c, tid))
                    seen_pairs.add((c, tid))
        chunk_targets.sort(key=lambda kv: -len(kv[0]))

    queries = args.query
    if not queries and not sys.stdin.isatty():
        queries = [line.rstrip("\n") for line in sys.stdin if line.strip()]

    for q in queries:
        printed_any = False
        for snip, tid in snippet_items:
            if snip in q:
                graded = quality_map.get(snip) or templates.get(tid, {}).get(
                    "snippet_quality"
                ) or "weak"
                quality = match_quality(snip, graded, q)
                if not at_least(quality, min_quality):
                    continue
                verdict = "UNIQUE" if at_least(quality, "medium") else "WEAK"
                meta = templates.get(tid, {})
                print(
                    f"{q}\t{verdict}\t{tid}\t{snip}\t{meta.get('severity','')}\t{meta.get('name','')}\t{quality}"
                )
                printed_any = True
        for chunk, tid in chunk_targets:
            if chunk in q:
                meta = templates.get(tid, {})
                print(
                    f"{q}\tAMBIGUOUS\t{tid}\t{chunk}\t{meta.get('severity','')}\t{meta.get('name','')}"
                )
                printed_any = True
        if not printed_any:
            print(f"{q}\tNO_MATCH")
    return 0


def _fingerprint(args: argparse.Namespace) -> int:
    lookup = json.loads(args.lookup.read_text())
    events = parse_events_jsonl(str(args.events))
    fp = actor_fingerprint(events, lookup, actor_id=args.actor_id, min_quality=args.min_quality)
    text = to_yaml(fp)
    if args.out:
        args.out.write_text(text)
        print(f"Wrote {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(text + "\n")
    return 0


def _compare(args: argparse.Namespace) -> int:
    from .actor import to_yaml as _to_yaml

    a = _load_fingerprint(args.a)
    b = _load_fingerprint(args.b)
    diff = _diff_fingerprints(a, b)
    print(_to_yaml(diff))
    return 0


def _match(args: argparse.Namespace) -> int:
    lookup = json.loads(args.lookup.read_text())
    events = parse_events_jsonl(str(args.events))
    reference = _load_fingerprint(args.actor)
    fresh = actor_fingerprint(events, lookup, actor_id="candidate", min_quality=args.min_quality)["actor_fingerprint"]
    ref = reference["actor_fingerprint"]
    score, findings = _match_score(ref, fresh)
    result = {
        "reference_actor": ref["id"],
        "reference_hash": ref["structural_hash"],
        "candidate_hash": fresh["structural_hash"],
        "match_score": score,
        "signals": findings,
    }
    print(to_yaml(result))
    return 0


def _load_fingerprint(path: Path) -> dict:
    """Parse a fingerprint YAML back. We use a minimal parser that only
    understands the shape our own dumper produces, to avoid pulling in a
    YAML runtime dependency for input-side use."""
    import yaml  # PyYAML is already a dep for parsing Nuclei templates.

    return yaml.safe_load(path.read_text())


def _diff_fingerprints(a: dict, b: dict) -> dict:
    """Field-by-field diff of two fingerprint dicts.

    Returns `{"identical": bool, "diverged_fields": {path: {a, b}}}`.
    """
    diverged: dict[str, dict] = {}
    _diff_walk(a, b, [], diverged)
    return {
        "identical": not diverged,
        "reference_hash_a": (a.get("actor_fingerprint") or {}).get("structural_hash"),
        "reference_hash_b": (b.get("actor_fingerprint") or {}).get("structural_hash"),
        "diverged_fields": diverged,
    }


def _diff_walk(a, b, path, out: dict) -> None:
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            _diff_walk(a.get(k), b.get(k), path + [str(k)], out)
        return
    if a != b:
        out[".".join(path)] = {"a": a, "b": b}


def _match_score(reference: dict, candidate: dict) -> tuple[float, list[str]]:
    """Score how well `candidate` matches `reference` (0.0-1.0)."""
    findings: list[str] = []
    supporting = 0
    contradicting = 0

    both_low_signal = reference.get("low_signal") and candidate.get("low_signal")
    if reference.get("structural_hash") == candidate.get("structural_hash"):
        if both_low_signal:
            # Identical hash on two signal-poor actors is weak evidence: the
            # hash rests on inferred rate/strategy shape, not on trustworthy
            # template or runtime signal. Report a capped, flagged score
            # rather than asserting "same actor."
            findings.append(
                "structural_hash identical BUT both fingerprints are low-signal "
                "(no trusted template hits, no Nuclei UA) -- identity is not established"
            )
            return 0.5, findings
        findings.append("structural_hash identical")
        return 1.0, findings

    # Tool match
    if (reference.get("tool_inference") or {}).get("likely_tool") == (
        candidate.get("tool_inference") or {}
    ).get("likely_tool"):
        supporting += 1
        findings.append("likely_tool matches")
    else:
        contradicting += 1
        findings.append("likely_tool differs")

    # Template subset overlap (Jaccard)
    ref_templates = set(
        (reference.get("template_preference") or {}).get("matched") or []
    )
    cand_templates = set(
        (candidate.get("template_preference") or {}).get("matched") or []
    )
    if ref_templates or cand_templates:
        overlap = len(ref_templates & cand_templates) / max(
            1, len(ref_templates | cand_templates)
        )
        findings.append(
            f"template Jaccard {overlap:.2f} "
            f"({len(ref_templates & cand_templates)}/{len(ref_templates | cand_templates)})"
        )
        if overlap >= 0.5:
            supporting += 1
        elif overlap < 0.2:
            contradicting += 1

    # CLI option overlap on each field.
    ref_cli = reference.get("inferred_cli_options") or {}
    cand_cli = candidate.get("inferred_cli_options") or {}
    for key in ("-severity", "-tags", "-random-agent", "-scan-strategy"):
        if key not in ref_cli and key not in cand_cli:
            continue
        if ref_cli.get(key) == cand_cli.get(key):
            supporting += 1
            findings.append(f"{key} matches")
        else:
            contradicting += 1
            findings.append(f"{key} differs (ref={ref_cli.get(key)!r} cand={cand_cli.get(key)!r})")

    # Interactsh host
    ref_ish = (ref_cli.get("-interactsh-server") or {}).get("host") if ref_cli.get("-interactsh-server") else None
    cand_ish = (cand_cli.get("-interactsh-server") or {}).get("host") if cand_cli.get("-interactsh-server") else None
    if ref_ish or cand_ish:
        if ref_ish == cand_ish:
            supporting += 1
            findings.append(f"-interactsh-server matches ({ref_ish})")
        else:
            contradicting += 1
            findings.append(f"-interactsh-server differs (ref={ref_ish} cand={cand_ish})")

    # Additive score with baseline 0.5. Contradictions weigh slightly more
    # than supporting signals, and any contradiction at all caps the score
    # below 1.0 -- we reserve 1.0 for structural_hash identity, handled
    # above by the short-circuit.
    raw = 0.5 + 0.1 * supporting - 0.15 * contradicting
    score = max(0.0, min(0.95 if contradicting else 1.0, raw))
    return round(score, 2), findings


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="nucleotide",
        description=(
            "Reverse-engineer threat-actor tool and CLI choices from "
            "observed Nuclei traffic. Emits per-tier Snort/Suricata + "
            "Sigma detection rules and portable actor-behavior "
            "fingerprints."
        ),
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    bld = sub.add_parser("build", help="Fetch templates and build the lookup table.")
    bld.add_argument("--repo", default=PROJECTDISCOVERY_REPO, help="Template repo URL.")
    bld.add_argument(
        "--templates-dir",
        type=Path,
        default=None,
        help="Use an existing local template tree instead of fetching.",
    )
    bld.add_argument(
        "--cache-dir",
        type=Path,
        default=Path.home() / ".cache" / "nucleotide" / "templates",
        help="Where to clone templates if --templates-dir is not set.",
    )
    bld.add_argument("--out", type=Path, default=Path("nucleotide-lookup.json"))
    bld.add_argument(
        "--min-len",
        type=int,
        default=4,
        help="Minimum snippet length. Increase (e.g. 6 or 8) for higher precision against arbitrary log traffic.",
    )
    bld.add_argument(
        "--no-fetch",
        action="store_true",
        help="Reuse the cache directory without pulling updates.",
    )
    bld.add_argument(
        "--yara-out",
        type=Path,
        default=None,
        help="Also write per-template YARA rules to this path.",
    )
    bld.add_argument(
        "--snort-out",
        type=Path,
        default=None,
        help="Also write per-template Snort/Suricata rules (all tiers) to this path.",
    )
    bld.add_argument(
        "--snort-out-dir",
        type=Path,
        default=None,
        help="Also write per-tier Snort/Suricata rules (nuclei-t1.rules ... nuclei-t5.rules) to this directory.",
    )
    bld.add_argument(
        "--sigma-out",
        type=Path,
        default=None,
        help="Also write a combined Sigma rule collection (T1 + T5) to this path.",
    )
    bld.add_argument(
        "--sigma-out-dir",
        type=Path,
        default=None,
        help="Also write per-tier Sigma rule collections (nuclei-t1.yml, nuclei-t5.yml) to this directory.",
    )
    bld.set_defaults(func=_build)

    look = sub.add_parser(
        "lookup", help="Match URLs (args or stdin) against a built lookup file."
    )
    look.add_argument("lookup_file", type=Path)
    look.add_argument("query", nargs="*")
    look.add_argument(
        "--strict",
        action="store_true",
        help="Only report 1:1 unique-snippet matches; suppress shared-path (AMBIGUOUS) hits.",
    )
    look.add_argument(
        "--min-chunk",
        type=int,
        default=8,
        help="Minimum length for shared-path chunks considered in AMBIGUOUS lookup (default 8).",
    )
    look.add_argument(
        "--min-quality",
        choices=["weak", "medium", "strong"],
        default="weak",
        help="Minimum snippet-quality tier for a UNIQUE hit. 'weak' (default) "
        "reports all but labels sub-medium hits as WEAK; 'medium' suppresses "
        "coincidental mid-token fragments; 'strong' keeps only long anchored snippets.",
    )
    look.set_defaults(func=_lookup)

    fp = sub.add_parser(
        "fingerprint",
        help="Produce a portable actor fingerprint YAML from a batch of observation events.",
    )
    fp.add_argument("events", type=Path, help="Path to a JSONL file of observation events.")
    fp.add_argument("--lookup", type=Path, required=True, help="Path to nucleotide-lookup.json.")
    fp.add_argument("--out", type=Path, default=None, help="Write fingerprint here (default: stdout).")
    fp.add_argument("--actor-id", type=str, default=None, help="Optional stable actor id; auto-derived from structural hash if omitted.")
    fp.add_argument(
        "--min-quality",
        choices=["weak", "medium", "strong"],
        default="medium",
        help="Snippet-quality floor for a template hit to drive tool/CLI inference "
        "and the structural hash (default medium). Hits below the floor are "
        "reported under weak_only_matches only.",
    )
    fp.set_defaults(func=_fingerprint)

    cmp = sub.add_parser(
        "compare",
        help="Diff two actor fingerprint YAML files field-by-field.",
    )
    cmp.add_argument("a", type=Path)
    cmp.add_argument("b", type=Path)
    cmp.set_defaults(func=_compare)

    mch = sub.add_parser(
        "match",
        help="Score how well a fresh batch of events matches an existing actor fingerprint.",
    )
    mch.add_argument("events", type=Path)
    mch.add_argument("actor", type=Path, help="Path to a reference actor fingerprint YAML.")
    mch.add_argument("--lookup", type=Path, required=True)
    mch.add_argument(
        "--min-quality",
        choices=["weak", "medium", "strong"],
        default="medium",
        help="Snippet-quality floor for a template hit to drive tool/CLI inference "
        "and the structural hash (default medium). Hits below the floor are "
        "reported under weak_only_matches only.",
    )
    mch.set_defaults(func=_match)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
