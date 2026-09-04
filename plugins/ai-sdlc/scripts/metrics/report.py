#!/usr/bin/env python3
"""report.py: DORA keys plus counterweights from the normalised metrics export.

    python report.py raw.json [--baseline baseline.json] [--cost-dir DIR] [--out report.md] [--json]

Input is the file `sdlc-platform metrics_export` writes (identical shape on GitHub and Azure
DevOps): prs[], deployments[], incidents[], reverts[], and optionally sources{} and warnings[].
Output is Markdown that states, for each number, how it was measured and on how many records,
so a reader can tell an indicative number from a conclusive one. Standard library only.

Cost records. --cost-dir holds JSON files of three shapes. Every file is reduced to canonical
run records before anything is summed, so a run that appears in several files counts once:

  * a dict with "runs_detail" (a cost/report.sh summary) contributes its detail rows and never
    its own total_cost_usd;
  * any other dict is one record (a `claude -p --output-format json` result or an
    sdlc-cost.json record);
  * a list (a claude-code-action execution file) contributes its {"type": "result"} entries.

The dedup key of a record is run_id, else session_id (a summary row's "session" field carries
the same value), else the composite fallback "<cost_usd>|<num_turns>|<recorded_at>|<pr>", with
cost_usd printed to 6 decimals, a missing num_turns read as 0 and a missing recorded_at or pr
as an empty string, so a raw record and a summary row for the same id-less run agree. Two
id-less runs with identical cost, turns, timestamp and PR therefore collapse into one; the
data-quality warnings say when records were collapsed. Malformed files (invalid JSON, a
non-numeric cost, a shape that is none of the three) become warnings, never a silent skip.

Unavailable sources. When the export says sources.<name> == "not-configured", the metrics that
need that source are rendered as "source not configured" instead of a measured zero or n/a, and
the sample line says so. Export warnings are carried into the report's Data quality section.
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
from datetime import datetime, timezone
from typing import Any, Optional

NOT_CONFIGURED = "not-configured"
SOURCE_OK = ("ok", "configured", "", None)
# Which metrics cannot be measured when a source is not configured. Reverts feed only one half
# of the change failure rate and PRs feed everything, so those two sources get a warning line
# instead of a blanket "unavailable".
SOURCE_METRICS = {
    "deployments": ["deployment_frequency_per_week", "lead_time_h_p50", "lead_time_h_p90",
                    "change_failure_rate", "defect_escape_rate"],
    "incidents": ["defect_escape_rate"],
}


def parse_ts(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        try:
            dt = datetime.strptime(text[:19], "%Y-%m-%dT%H:%M:%S")
        except ValueError:
            return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def hours(a: Optional[datetime], b: Optional[datetime]) -> Optional[float]:
    if a is None or b is None:
        return None
    return (b - a).total_seconds() / 3600.0


def pct(values: list[float], q: float) -> Optional[float]:
    if not values:
        return None
    ordered = sorted(values)
    idx = min(len(ordered) - 1, max(0, int(round(q * (len(ordered) - 1)))))
    return ordered[idx]


def fmt(value: Optional[float], unit: str = "", digits: int = 1) -> str:
    if value is None:
        return "n/a"
    if unit == "%":
        return f"{value * 100:.{digits}f}%"
    if unit == "h":
        if value >= 48:
            return f"{value / 24:.{digits}f} d"
        return f"{value:.{digits}f} h"
    if unit == "$":
        return f"${value:.2f}"
    return f"{value:.{digits}f}{unit}"


def _as_text(value: Any) -> str:
    return value if isinstance(value, str) else json.dumps(value, sort_keys=True)


def export_sources(raw: dict[str, Any]) -> tuple[dict[str, str], list[str]]:
    """The export's sources{} as name -> status, plus warnings for anything odd in it."""
    warnings: list[str] = []
    sources = raw.get("sources")
    if sources is None:
        return {}, warnings
    if not isinstance(sources, dict):
        return {}, [f"export: sources is {type(sources).__name__}, expected an object"]
    out: dict[str, str] = {}
    for name, status in sources.items():
        out[str(name)] = _as_text(status) if not isinstance(status, str) else status
    return out, warnings


def export_warnings(raw: dict[str, Any]) -> list[str]:
    items = raw.get("warnings")
    if items is None:
        return []
    if not isinstance(items, list):
        return [f"export: warnings is {type(items).__name__}, expected a list"]
    return [f"export: {_as_text(w)}" for w in items]


def compute(raw: dict[str, Any], cost_records: Optional[list[dict[str, Any]]] = None,
            cost_warnings: Optional[list[str]] = None, cost_files: int = 0) -> dict[str, Any]:
    since = parse_ts(raw.get("since") + "T00:00:00Z" if raw.get("since") and len(raw["since"]) == 10 else raw.get("since"))
    until = parse_ts(raw.get("until") + "T23:59:59Z" if raw.get("until") and len(raw["until"]) == 10 else raw.get("until"))
    days = max(1.0, ((until - since).total_seconds() / 86400.0) if since and until else 30.0)

    sources, warnings = export_sources(raw)
    warnings += export_warnings(raw)
    not_configured = {n for n, st in sources.items() if st == NOT_CONFIGURED}

    prs = raw.get("prs", []) or []
    deployments = raw.get("deployments", []) or []
    incidents = raw.get("incidents", []) or []
    reverts = raw.get("reverts", []) or []
    for name, rows in (("deployments", deployments), ("incidents", incidents), ("reverts", reverts)):
        if name in not_configured and rows:
            warnings.append(f"export: sources.{name} is {NOT_CONFIGURED} but the export holds "
                            f"{len(rows)} {name}; they were ignored")
    if "deployments" in not_configured:
        deployments = []
    if "incidents" in not_configured:
        incidents = []
    if "reverts" in not_configured:
        reverts = []
        warnings.append("export: reverts: source not configured; change failure rate counts "
                        "failed deployments only")
    if "prs" in not_configured:
        warnings.append("export: prs: source not configured; PR-based metrics are unavailable")
    for name, status in sorted(sources.items()):
        if status not in SOURCE_OK and status != NOT_CONFIGURED:
            warnings.append(f"export: {name}: source status is {status}")

    successful = [d for d in deployments if d.get("status") == "success"]
    failed = [d for d in deployments if d.get("status") == "failure"]
    deploy_times = sorted(t for t in (parse_ts(d.get("finished_at") or d.get("started_at")) for d in successful) if t)

    # Lead time: first commit (fallback: PR created) -> first successful deployment at or after merge.
    lead_times: list[float] = []
    for pr in prs:
        merged = parse_ts(pr.get("merged_at"))
        start = parse_ts(pr.get("first_commit_at")) or parse_ts(pr.get("created_at"))
        if not merged or not start:
            continue
        deploy_after = next((t for t in deploy_times if t >= merged), None)
        if deploy_after is None:
            continue
        lt = hours(start, deploy_after)
        if lt is not None and lt >= 0:
            lead_times.append(lt)

    # Change failure rate: failed deployments, plus successful deployments whose commit was reverted.
    reverted_shas = {(r.get("reverts_sha") or "")[:7] for r in reverts if r.get("reverts_sha")}
    reverted_deploys = [d for d in successful if (d.get("sha") or "")[:7] in reverted_shas]
    cfr = ((len(failed) + len(reverted_deploys)) / len(deployments)) if deployments else None

    # MTTR: incident open -> close for closed incidents; failed deployment -> next successful deployment.
    recovery: list[float] = []
    for inc in incidents:
        h = hours(parse_ts(inc.get("opened_at")), parse_ts(inc.get("closed_at")))
        if h is not None and h >= 0:
            recovery.append(h)
    for d in failed:
        failed_at = parse_ts(d.get("finished_at") or d.get("started_at"))
        nxt = next((t for t in deploy_times if failed_at and t > failed_at), None)
        h = hours(failed_at, nxt)
        if h is not None:
            recovery.append(h)

    merged_prs = [p for p in prs if p.get("merged_at")]
    revert_prs = [p for p in merged_prs if p.get("is_revert")]
    sizes = [(p.get("additions") or 0) + (p.get("deletions") or 0) for p in merged_prs if p.get("additions") is not None and p.get("deletions") is not None]
    review_latency = [h for h in (hours(parse_ts(p.get("created_at")), parse_ts(p.get("first_review_at"))) for p in merged_prs) if h is not None and h >= 0]
    churn_per_week = (sum(sizes) / days * 7.0) if sizes else None
    defect_escape = (len(incidents) / len(successful)) if successful else None
    total = cost_total(cost_records) if cost_records is not None else None
    cost_per_pr = (total / len(merged_prs)) if (total is not None and merged_prs) else None

    def count(name: str, rows: list[Any]) -> Optional[int]:
        return None if name in not_configured else len(rows)

    metrics = {
        "period": {"since": raw.get("since"), "until": raw.get("until"), "days": round(days, 1), "platform": raw.get("platform"), "repo": raw.get("repo")},
        "samples": {
            "prs": len(merged_prs), "prs_with_size": len(sizes),
            "deployments": count("deployments", deployments),
            "successful_deployments": count("deployments", successful),
            "incidents": count("incidents", incidents),
            "reverts": count("reverts", reverts),
        },
        "dora": {
            "deployment_frequency_per_week": (len(successful) / days * 7.0) if deployments else None,
            "lead_time_h_p50": statistics.median(lead_times) if lead_times else None,
            "lead_time_h_p90": pct(lead_times, 0.9),
            "lead_time_samples": len(lead_times),
            "change_failure_rate": cfr,
            "mttr_h": statistics.mean(recovery) if recovery else None,
            "mttr_samples": len(recovery),
        },
        "counterweights": {
            "revert_rate": (len(revert_prs) / len(merged_prs)) if merged_prs else None,
            "pr_size_p50": statistics.median(sizes) if sizes else None,
            "pr_size_p90": pct(sizes, 0.9),
            "review_latency_h_p50": statistics.median(review_latency) if review_latency else None,
            "review_latency_samples": len(review_latency),
            "code_churn_lines_per_week": churn_per_week,
            "defect_escape_rate": defect_escape,
            "cost_per_merged_pr_usd": cost_per_pr,
            "cost_total_usd": total,
        },
        "sources": sources,
        "unavailable": {},
        "data_quality": {
            "warnings": warnings + [f"cost: {w}" for w in (cost_warnings or [])],
            "cost_records": len(cost_records or []),
            "cost_files": cost_files,
        },
    }
    # A metric whose source is not configured is unavailable, whatever the arrays held.
    for source in sorted(not_configured):
        for key in SOURCE_METRICS.get(source, []):
            metrics["unavailable"].setdefault(key, f"{source}: source not configured")
            for section in ("dora", "counterweights"):
                if key in metrics[section]:
                    metrics[section][key] = None
    return metrics


# --- cost records -----------------------------------------------------------------------------

def list_cost_files(cost_dir: Optional[str]) -> list[str]:
    if not cost_dir or not os.path.isdir(cost_dir):
        return []
    return sorted(n for n in os.listdir(cost_dir) if n.endswith(".json"))


def _cost_value(value: Any) -> Optional[float]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return None
    return None


def _id_value(value: Any) -> Optional[str]:
    if value is None or isinstance(value, bool):
        return None
    text = str(value).strip()
    return text or None


def cost_record(row: Any, name: str, what: str) -> tuple[Optional[dict[str, Any]], Optional[str]]:
    """Normalise one run row (raw result, sdlc-cost.json record or summary detail row)."""
    if not isinstance(row, dict):
        return None, f"{name}: {what} is {type(row).__name__}, expected an object"
    if "total_cost_usd" in row:
        raw_cost = row["total_cost_usd"]
    elif "cost_usd" in row:
        raw_cost = row["cost_usd"]
    else:
        return None, f"{name}: {what} has neither total_cost_usd nor cost_usd"
    cost = _cost_value(raw_cost)
    if cost is None:
        return None, f"{name}: {what} has a non-numeric cost {raw_cost!r}"
    turns_raw = row.get("num_turns", row.get("turns"))
    turns = _cost_value(turns_raw)
    turns_int = int(turns) if turns is not None else 0
    run_id = _id_value(row.get("run_id"))
    session_id = _id_value(row.get("session_id"))
    session = _id_value(row.get("session"))
    recorded_at = row.get("recorded_at")
    pr = row.get("pr")
    key = run_id or session_id or session
    if key is None:
        key = "|".join([f"{cost:.6f}", str(turns_int),
                        "" if recorded_at is None else str(recorded_at),
                        "" if pr is None else str(pr)])
    return {
        "file": name, "cost_usd": cost, "turns": turns_int, "run_id": run_id,
        "session_id": session_id or session, "recorded_at": recorded_at, "pr": pr, "key": key,
    }, None


def load_cost_records(cost_dir: Optional[str]) -> tuple[list[dict[str, Any]], list[str]]:
    """Canonical, deduplicated run records from every .json file in cost_dir, plus warnings.

    See the module docstring for the three accepted shapes and the dedup key. A missing or
    non-directory cost_dir yields no records and no warnings (cost is simply not tracked).
    """
    records: list[dict[str, Any]] = []
    warnings: list[str] = []
    seen: set[str] = set()
    duplicates = 0
    for name in list_cost_files(cost_dir):
        path = os.path.join(cost_dir or "", name)
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
        except OSError as exc:
            warnings.append(f"{name}: cannot read ({exc.strerror or exc})")
            continue
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            detail = f"{exc.msg} at line {exc.lineno}" if isinstance(exc, json.JSONDecodeError) else str(exc)
            warnings.append(f"{name}: invalid JSON ({detail})")
            continue
        if isinstance(data, dict) and "runs_detail" in data:
            detail_rows = data["runs_detail"]
            if not isinstance(detail_rows, list):
                warnings.append(f"{name}: runs_detail is {type(detail_rows).__name__}, expected a list")
                continue
            candidates = [(r, f"runs_detail[{i}]") for i, r in enumerate(detail_rows)]
        elif isinstance(data, dict):
            candidates = [(data, "record")]
        elif isinstance(data, list):
            candidates = [(e, f"result entry [{i}]") for i, e in enumerate(data)
                          if isinstance(e, dict) and e.get("type") == "result"]
            if not candidates:
                warnings.append(f"{name}: execution file has no {{\"type\": \"result\"}} entry")
                continue
        else:
            warnings.append(f"{name}: top-level value is {type(data).__name__}, "
                            "expected an object or a list")
            continue
        for row, what in candidates:
            record, warning = cost_record(row, name, what)
            if warning:
                warnings.append(warning)
                continue
            if record["key"] in seen:
                duplicates += 1
                continue
            seen.add(record["key"])
            records.append(record)
    if duplicates:
        warnings.append(f"{duplicates} run record(s) appeared more than once across the cost "
                        "files (same run_id, session_id or composite key) and were counted once")
    return records, warnings


def cost_total(records: Optional[list[dict[str, Any]]]) -> Optional[float]:
    if not records:
        return None
    return round(sum(r["cost_usd"] for r in records), 6)


def load_cost_total(cost_dir: Optional[str]) -> Optional[float]:
    """Compatibility wrapper: the deduplicated total, or None when there are no records."""
    records, _warnings = load_cost_records(cost_dir)
    return cost_total(records)


# --- rendering --------------------------------------------------------------------------------

def delta(current: Optional[float], base: Optional[float], unit: str, lower_is_better: bool) -> str:
    if current is None or base is None:
        return ""
    diff = current - base
    if abs(diff) < 1e-9:
        return " (unchanged)"
    direction = "better" if (diff < 0) == lower_is_better else "worse"
    return f" ({'+' if diff > 0 else ''}{fmt(diff, unit)} vs baseline, {direction})"


def render(m: dict[str, Any], base: Optional[dict[str, Any]]) -> str:
    s, d, c, p = m["samples"], m["dora"], m["counterweights"], m["period"]
    unavailable: dict[str, str] = m.get("unavailable") or {}
    quality: dict[str, Any] = m.get("data_quality") or {}
    bd = base["dora"] if base else {}
    bc = base["counterweights"] if base else {}
    conclusive = (s["deployments"] or 0) >= 10 and s["prs"] >= 20

    def cell(section: dict[str, Any], key: str, unit: str, digits: int = 1,
             lower_is_better: bool = True, base_section: Optional[dict[str, Any]] = None) -> str:
        if key in unavailable:
            return "source not configured"
        value = section[key]
        baseline = (base_section if base_section is not None else {}).get(key)
        return fmt(value, unit, digits) + delta(value, baseline, unit, lower_is_better)

    def pair(section: dict[str, Any], k50: str, k90: str, unit: str, digits: int = 1,
             base_section: Optional[dict[str, Any]] = None) -> str:
        if k50 in unavailable:
            return "source not configured"
        baseline = (base_section if base_section is not None else {}).get(k50)
        return (f"{fmt(section[k50], unit, digits)} / {fmt(section[k90], unit, digits)}"
                f"{delta(section[k50], baseline, unit, True)}")

    def sample(name: str, text: str) -> str:
        return f"{name}: source not configured" if s.get(name) is None else text

    sample_parts = [
        f"{s['prs']} merged PRs",
        sample("deployments", f"{s['deployments']} deployments ({s['successful_deployments']} successful)"),
        sample("incidents", f"{s['incidents']} incidents"),
        sample("reverts", f"{s['reverts']} reverts"),
    ]
    if conclusive:
        confidence = "Sample size is large enough to read as a trend."
    elif s["deployments"] is None:
        confidence = ("**Indicative only**: deployments are not measured (source not configured), so "
                      f"the DORA keys that need them are unavailable and the rest rests on {s['prs']} "
                      "PRs. Direction, not magnitude.")
    else:
        confidence = "**Indicative only**: fewer than 10 deployments or 20 PRs. Direction, not magnitude."
    lines = [
        f"# SDLC metrics: {p.get('repo') or 'repository'} ({p.get('platform') or 'platform'}), {p.get('since')} to {p.get('until')}",
        "",
        f"Sample: {', '.join(sample_parts)} over {p['days']} days.",
        confidence,
        "",
        "## DORA keys",
        "",
        "| Metric | Value | How measured |",
        "| --- | --- | --- |",
        f"| Deployment frequency | {cell(d, 'deployment_frequency_per_week', ' / week', 1, False, bd)} | successful production deployments per 7 days |",
        f"| Lead time for changes (p50 / p90) | {pair(d, 'lead_time_h_p50', 'lead_time_h_p90', 'h', 1, bd)} | first commit (or PR opened) to the first successful deployment after merge; {d['lead_time_samples']} PRs |",
        f"| Change failure rate | {cell(d, 'change_failure_rate', '%', 1, True, bd)} | failed deployments plus deployments whose commit was reverted, over all deployments |",
        f"| Time to restore (MTTR) | {cell(d, 'mttr_h', 'h', 1, True, bd)} | mean of incident open to close, and failed deployment to next success; {d['mttr_samples']} events |",
        "",
        "## Counterweights",
        "",
        "| Metric | Value | How measured |",
        "| --- | --- | --- |",
        f"| Revert rate | {cell(c, 'revert_rate', '%', 1, True, bc)} | merged PRs titled Revert over merged PRs |",
        f"| PR size (p50 / p90) | {pair(c, 'pr_size_p50', 'pr_size_p90', ' lines', 0, bc)} | additions + deletions; {s['prs_with_size']} of {s['prs']} PRs had size data |",
        f"| Review latency (p50) | {cell(c, 'review_latency_h_p50', 'h', 1, True, bc)} | PR opened to first review; {c['review_latency_samples']} PRs |",
        f"| Code churn | {cell(c, 'code_churn_lines_per_week', ' lines / week', 0, True, bc)} | lines changed in merged PRs per 7 days |",
        f"| Defect escape rate | {cell(c, 'defect_escape_rate', '%', 1, True, bc)} | incidents over successful deployments |",
        f"| Cost per merged PR | {cell(c, 'cost_per_merged_pr_usd', '$', 1, True, bc)} | agent spend from .sdlc/metrics/cost over merged PRs (total {fmt(c['cost_total_usd'], '$')}, {quality.get('cost_records', 0)} run records) |",
    ]

    quality_lines: list[str] = []
    for source in sorted({v.split(":", 1)[0] for v in unavailable.values()}):
        rows = [k for k, v in unavailable.items() if v.startswith(f"{source}:")]
        quality_lines.append(f"- {source}: source not configured. Unavailable, not zero: "
                             f"{', '.join(METRIC_LABELS.get(k, k) for k in rows)}.")
    quality_lines += [f"- {w}" for w in quality.get("warnings", [])]
    if quality_lines:
        if quality.get("cost_files"):
            quality_lines.append(f"- cost: {quality.get('cost_records', 0)} canonical run record(s) "
                                 f"from {quality['cost_files']} file(s); duplicates count once.")
        lines += ["", "## Data quality", ""] + quality_lines

    lines += [
        "",
        "## Reading these numbers",
        "",
        "- Self-reported speed and measured speed frequently diverge. When the team feels faster and lead time or deployment frequency did not move, the measured numbers win.",
        "- A speed metric that improved while a counterweight worsened (larger PRs, more reverts, longer review latency, higher defect escape) is a trade, not a win. Name the trade.",
        "- Compare against the baseline captured before Tier 1 was installed; a period without a baseline is a start, not a result.",
    ]
    return "\n".join(lines) + "\n"


METRIC_LABELS = {
    "deployment_frequency_per_week": "deployment frequency",
    "lead_time_h_p50": "lead time (p50)",
    "lead_time_h_p90": "lead time (p90)",
    "change_failure_rate": "change failure rate",
    "mttr_h": "time to restore",
    "defect_escape_rate": "defect escape rate",
}


def main() -> int:
    # Windows consoles default to a legacy code page; the report is always UTF-8.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("raw", help="normalised metrics export (from sdlc-platform metrics_export)")
    ap.add_argument("--baseline", help="an earlier report's --json output or a baseline raw export")
    ap.add_argument("--cost-dir", help="directory of cost JSON files (cost/report.sh output or sdlc-cost.json records)")
    ap.add_argument("--out", help="write the Markdown report here")
    ap.add_argument("--json", action="store_true", help="print the computed metrics as JSON instead of Markdown")
    args = ap.parse_args()

    with open(args.raw, encoding="utf-8") as fh:
        raw = json.load(fh)
    cost_records, cost_warnings = load_cost_records(args.cost_dir)
    metrics = compute(raw, cost_records if args.cost_dir else None, cost_warnings,
                      len(list_cost_files(args.cost_dir)))

    base = None
    if args.baseline:
        with open(args.baseline, encoding="utf-8") as fh:
            base_data = json.load(fh)
        base = base_data if "dora" in base_data else compute(base_data)

    if args.json:
        print(json.dumps(metrics, indent=2))
    text = render(metrics, base)
    if args.out:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
    if not args.json:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
