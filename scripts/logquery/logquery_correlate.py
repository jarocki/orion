"""logquery_correlate — targeted vs widespread, judged from the operator's own history.

@decision DEC-PHASE12-027
@title The correlation is pure Python, not SQL, so it never depends on an engine
@status accepted
@rationale Upstream expresses its best report — `targeted` — as a DuckDB query
  with window-ish aggregates, `any_value()` and `::int` casts. That makes the
  single most valuable judgement in the tool contingent on a third-party
  database being importable, and it makes the scoring formula unreviewable by
  anyone who is not reading SQL.

  This is the one thing the Cockpit cannot currently say. scanwatch
  (DEC-PHASE12-022) can report "one host touched 900 ports" but not "this host
  came back on four separate days, and it also loaded real pages, and almost
  nobody else has ever asked for the path it probed". That judgement is what
  turns an event into a lead. It must therefore work on a stock boot with
  nothing installed, so it is computed here in stdlib Python and the SQL engine
  is reserved for ad-hoc queries and tabular aggregates.

@decision DEC-PHASE12-027
@title Rarity is measured against the operator's own corpus, not only against intel
@status accepted
@rationale Upstream's "uncommon" signal comes from intel prevalence — a global
  judgement about how often a path is probed on the internet at large. That is
  useful and is kept. But it cannot answer the operator's actual question,
  which is comparative: out of everything that has ever touched THIS deck, how
  many touched what this source touched? A path probed by one source out of
  four hundred is a different fact from a path probed by all four hundred, and
  no external feed knows it. So the corpus computes its own path prevalence and
  contributes a `local_rare` signal that needs no intel at all — which also
  means the targeted/widespread verdict survives an unfreshened cache.
"""
from __future__ import annotations

import ipaddress
from collections import Counter, defaultdict
from datetime import datetime

# Reasons that mark a request as a probe rather than ordinary browsing.
PROBE_REASONS = ("decoy_path", "honeypot", "tokened_asset", "firewall_drop", "error")
REAL_PAGE_REASONS = ("normal", "bus_event")

# A path is locally rare when at most this many distinct sources ever asked for
# it, or at most this share of the corpus's sources, whichever is larger. The
# share matters: on a 6-record fixture "2 sources" is most of the corpus, while
# on a 40,000-record capture it is essentially nobody.
RARE_ABSOLUTE = 2
RARE_SHARE = 0.10

# Verdict thresholds over the composite signal.
TARGETED_SIGNAL = 5
ATTENTION_SIGNAL = 3

VERDICT_RESEARCH = "research-scanner"
VERDICT_TARGETED = "targeted"
VERDICT_ATTENTION = "worth-a-look"
VERDICT_WIDESPREAD = "widespread"


def _day(ts) -> str:
    return str(ts or "")[:10]


def path_prevalence(records: list[dict]) -> dict[str, int]:
    """How many distinct sources ever requested each path, in this corpus."""
    seen: dict[str, set] = defaultdict(set)
    for rec in records:
        ip = rec.get("ip")
        path = rec.get("path")
        if ip and path:
            seen[path].add(ip)
    return {path: len(ips) for path, ips in seen.items()}


def rare_threshold(source_count: int) -> int:
    """The 'touched by at most N sources' cutoff for this corpus size."""
    return max(RARE_ABSOLUTE, int(source_count * RARE_SHARE))


def per_source(records: list[dict]) -> dict[str, dict]:
    """Collapse the corpus into one row per source address.

    Every field here is evidence the operator can check, not a score: the
    score is derived from these in score_source() so that a disagreement with
    the verdict can be traced to the observation that produced it.
    """
    grouped: dict[str, dict] = {}
    for rec in records:
        ip = rec.get("ip")
        if not ip:
            continue
        state = grouped.get(ip)
        if state is None:
            state = grouped[ip] = {
                "ip": ip, "hits": 0, "days": set(), "paths": set(),
                "decoys": set(), "assets": set(), "probe_paths": set(),
                "browsed_real": 0, "errors": 0, "served": 0,
                "user_agents": set(), "null_ua": 0, "no_referer": 0,
                "tools": set(), "ports": set(), "spoof": set(),
                "research_org": "", "max_tier": 0, "prevalence_flags": set(),
                "first_seen": "", "last_seen": "", "hours": set(),
                "timestamps": [],
            }
        state["hits"] += 1
        ts = rec.get("ts") or ""
        if ts:
            state["days"].add(_day(ts))
            state["timestamps"].append(ts)
            if not state["first_seen"] or ts < state["first_seen"]:
                state["first_seen"] = ts
            if ts > state["last_seen"]:
                state["last_seen"] = ts
            try:
                state["hours"].add(int(ts[11:13]))
            except ValueError:
                pass

        path = rec.get("path") or ""
        reason = rec.get("reason") or ""
        status = rec.get("status")
        if path:
            state["paths"].add(path)
        if reason == "decoy_path":
            state["decoys"].add(path)
        if reason in ("tokened_asset", "honeypot"):
            state["assets"].add(path)
        if reason in PROBE_REASONS and path:
            state["probe_paths"].add(path)
        if isinstance(status, int):
            if status >= 400:
                state["errors"] += 1
            else:
                state["served"] += 1
                if reason in REAL_PAGE_REASONS or reason == "":
                    state["browsed_real"] = 1
        elif reason in REAL_PAGE_REASONS:
            state["browsed_real"] = 1

        ua = rec.get("userAgent")
        if ua:
            state["user_agents"].add(ua)
        else:
            state["null_ua"] += 1
        if not rec.get("referer"):
            state["no_referer"] += 1
        if rec.get("tool"):
            state["tools"].add(rec["tool"])
        if rec.get("port"):
            state["ports"].add(rec["port"])
        if rec.get("spoof"):
            state["spoof"].update(str(rec["spoof"]).split(";"))
        if rec.get("research_org"):
            state["research_org"] = rec["research_org"]
        if rec.get("prevalence"):
            state["prevalence_flags"].add(rec["prevalence"])
        tier = rec.get("tier")
        if isinstance(tier, int):
            state["max_tier"] = max(state["max_tier"], tier)
        state.setdefault("asn", rec.get("asn"))
        state.setdefault("org", rec.get("asOrganization"))
        if state.get("asn") is None:
            state["asn"] = rec.get("asn")
        if not state.get("org"):
            state["org"] = rec.get("asOrganization")
    return grouped


def score_source(state: dict, prevalence: dict[str, int], rare_cut: int) -> dict:
    """Turn one source's observations into signals, a score and a verdict.

    The score keeps upstream's weighting so a jarocki-edge operator reads the
    same numbers, and adds the corpus-rarity term:

      browsed_real AND probed   +3   the strongest single tell
      intel says uncommon       +2   global rarity (needs intel)
      locally rare probe        +2   rarity in THIS deck's own history
      recurring (>1 day)        +1   came back
      UA/network inconsistency  +1
      known research scanner    -3   Censys et al. are not your adversary
    """
    research = 1 if state.get("research_org") else 0
    probed = 1 if (state["decoys"] or state["assets"]
                   or state["probe_paths"] or state["errors"]) else 0
    browsed_and_probed = 1 if (state["browsed_real"] and probed) else 0
    intel_uncommon = 1 if state["prevalence_flags"] & {"low", "medium"} else 0
    recurring = 1 if len(state["days"]) > 1 else 0
    spoofed = 1 if {s for s in state["spoof"] if s} else 0

    rare_paths = sorted(p for p in state["probe_paths"]
                        if 0 < prevalence.get(p, 0) <= rare_cut)
    local_rare = 1 if rare_paths else 0

    signal = (browsed_and_probed * 3 + intel_uncommon * 2 + local_rare * 2
              + recurring + spoofed - research * 3)

    if research:
        verdict = VERDICT_RESEARCH
    elif signal >= TARGETED_SIGNAL:
        verdict = VERDICT_TARGETED
    elif signal >= ATTENTION_SIGNAL:
        verdict = VERDICT_ATTENTION
    else:
        verdict = VERDICT_WIDESPREAD

    reasons = []
    if browsed_and_probed:
        reasons.append("browsed real pages AND probed (the strongest tell)")
    if local_rare:
        reasons.append(f"probed {len(rare_paths)} path(s) almost nothing else here "
                       f"has asked for: {', '.join(rare_paths[:3])}")
    if intel_uncommon:
        reasons.append("hit a path intel rates uncommon")
    if recurring:
        reasons.append(f"recurring — active on {len(state['days'])} separate days")
    if spoofed:
        reasons.append("user-agent / network inconsistency: "
                       + ", ".join(sorted(s for s in state["spoof"] if s)))
    if state["tools"]:
        reasons.append("tool fingerprint: " + ", ".join(sorted(state["tools"])))
    if state["ports"] and len(state["ports"]) >= 15:
        reasons.append(f"touched {len(state['ports'])} distinct blocked ports")
    if research:
        reasons.append(f"known research scanner ({state['research_org']}) — downweighted")
    if not reasons:
        reasons.append("nothing beyond ordinary background probing")

    return {
        "ip": state["ip"],
        "org": state.get("org"),
        "asn": state.get("asn"),
        "verdict": verdict,
        "signal": signal,
        "hits": state["hits"],
        "active_days": len(state["days"]),
        "browsed_real": state["browsed_real"],
        "probed": probed,
        "decoys": len(state["decoys"]),
        "assets": len(state["assets"]),
        "errors": state["errors"],
        "served": state["served"],
        "distinct_paths": len(state["paths"]),
        "rare_paths": rare_paths,
        "local_rare": local_rare,
        "intel_uncommon": intel_uncommon,
        "spoofed": spoofed,
        "research_org": state.get("research_org", ""),
        "distinct_uas": len(state["user_agents"]),
        "null_ua": state["null_ua"],
        "tools": sorted(state["tools"]),
        "ports": len(state["ports"]),
        "max_tier": state["max_tier"],
        "first_seen": state["first_seen"],
        "last_seen": state["last_seen"],
        "reasons": reasons,
    }


def correlate(records: list[dict]) -> dict:
    """Score every source in the corpus. Returns rows plus corpus context.

    The corpus context is part of the answer, not decoration: "3 of 4 sources"
    and "3 of 40,000 sources" are different findings, and a caller that prints
    the rows without the denominator has lost the distinction.
    """
    grouped = per_source(records)
    prevalence = path_prevalence(records)
    rare_cut = rare_threshold(len(grouped))
    rows = [score_source(state, prevalence, rare_cut)
            for state in grouped.values()]
    rows.sort(key=lambda r: (-r["signal"], -r["hits"], r["ip"]))
    counts = Counter(row["verdict"] for row in rows)
    return {
        "rows": rows,
        "sources": len(grouped),
        "records": len(records),
        "distinct_paths": len(prevalence),
        "rare_threshold": rare_cut,
        "verdict_counts": dict(counts),
        "targeted": [r for r in rows if r["verdict"] == VERDICT_TARGETED],
    }


# ---------------------------------------------------------------------------
# similarity — is this source part of a group? (ported from upstream)
# ---------------------------------------------------------------------------
def _jaccard(a: set, b: set) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def shared_features(seed_ip: str, seed: dict, other_ip: str, other: dict) -> list[str]:
    """Behavioural features two sources share, in operator-readable words."""
    matched: list[str] = []
    try:
        if (ipaddress.ip_address(seed_ip).version == 4
                and ipaddress.ip_address(other_ip).version == 4
                and seed_ip.rsplit(".", 1)[0] == other_ip.rsplit(".", 1)[0]):
            matched.append("same /24 network block")
    except ValueError:
        pass
    if seed.get("asn") and seed.get("asn") == other.get("asn"):
        matched.append(f"same network (AS{seed['asn']} {seed.get('org') or ''})".strip())
    shared_decoys = seed["decoys"] & other["decoys"]
    if len(shared_decoys) >= 2:
        matched.append(f"probed {len(shared_decoys)} of the same decoy paths")
    if len(seed["paths"]) > 1 and _jaccard(seed["paths"], other["paths"]) >= 0.5:
        matched.append("near-identical set of requested paths")
    for a, b in ((seed, other),):
        if a["hits"] and b["hits"]:
            if a["errors"] / a["hits"] > 0.5 and b["errors"] / b["hits"] > 0.5:
                matched.append("both blind-request things that do not exist (mostly errors)")
            if a["no_referer"] / a["hits"] > 0.8 and b["no_referer"] / b["hits"] > 0.8:
                matched.append("both send requests with no Referer")
    if len(seed["user_agents"]) >= 3 and len(other["user_agents"]) >= 3:
        matched.append("both rotate through multiple user-agents")
    shared_ua = {u for u in (seed["user_agents"] & other["user_agents"]) if u}
    if shared_ua:
        matched.append("share an identical user-agent string")
    if seed["null_ua"] and other["null_ua"]:
        matched.append("both send empty user-agents")
    shared_tools = seed["tools"] & other["tools"]
    if shared_tools:
        matched.append("same tool fingerprint: " + ", ".join(sorted(shared_tools)))
    common_hours = seed["hours"] & other["hours"]
    if len(common_hours) >= 3 and len(seed["hours"]) <= 8 and len(other["hours"]) <= 8:
        matched.append("active in the same narrow hours (timing)")
    shared_ports = seed["ports"] & other["ports"]
    if len(shared_ports) >= 5:
        matched.append(f"probed {len(shared_ports)} of the same blocked ports")
    return matched


def similarity(records: list[dict], seed_ip: str, min_features: int = 2) -> dict:
    """Find sources behaving like the seed, and say which behaviours matched."""
    grouped = per_source(records)
    if seed_ip not in grouped:
        return {"seed": seed_ip, "found": False, "matches": [],
                "inactive_axes": ["JA3/JA4 TLS fingerprint (not captured)",
                                  "external OSINT reputation (not integrated)"]}
    seed = grouped[seed_ip]
    matches = []
    for ip, state in grouped.items():
        if ip == seed_ip:
            continue
        reasons = shared_features(seed_ip, seed, ip, state)
        if len(reasons) >= min_features:
            matches.append({"ip": ip, "hits": state["hits"],
                            "org": state.get("org"), "features": reasons})
    matches.sort(key=lambda m: (-len(m["features"]), -m["hits"], m["ip"]))
    return {
        "seed": seed_ip, "found": True, "seed_hits": seed["hits"],
        "seed_org": seed.get("org"), "matches": matches,
        # Named every run, so a missing match is never read as a cleared one.
        "inactive_axes": ["JA3/JA4 TLS fingerprint (not captured)",
                          "external OSINT reputation (not integrated)"],
    }


# ---------------------------------------------------------------------------
# cadence — machine-regular timing (ported from upstream)
# ---------------------------------------------------------------------------
def _parse(ts: str):
    try:
        return datetime.fromisoformat(str(ts))
    except ValueError:
        return None


def cadence(records: list[dict], min_requests: int = 3) -> list[dict]:
    """Per-source request rhythm; flags suspiciously even spacing."""
    grouped = per_source(records)
    rows = []
    for ip, state in grouped.items():
        stamps = sorted(t for t in (_parse(s) for s in state["timestamps"]) if t)
        if len(stamps) < min_requests:
            continue
        gaps = [(stamps[i + 1] - stamps[i]).total_seconds()
                for i in range(len(stamps) - 1)]
        mean = sum(gaps) / len(gaps)
        variance = sum((g - mean) ** 2 for g in gaps) / len(gaps)
        cv = (variance ** 0.5 / mean) if mean > 0 else 0.0
        rows.append({
            "ip": ip, "requests": len(stamps), "mean_gap_s": round(mean, 2),
            "cv": round(cv, 3),
            "machine_regular": bool(cv < 0.25 and len(gaps) >= 4),
            "org": state.get("org"),
        })
    rows.sort(key=lambda r: (not r["machine_regular"], r["mean_gap_s"]))
    return rows
