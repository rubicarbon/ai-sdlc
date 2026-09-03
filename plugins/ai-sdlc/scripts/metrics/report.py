#!/usr/bin/env python3
"""report.py: DORA keys plus counterweights from the normalised metrics export.

    python report.py raw.json [--baseline baseline.json] [--cost-dir DIR] [--out report.md] [--json]

Input is the file `sdlc-platform metrics_export` writes (identical shape on GitHub and Azure
DevOps): prs[], deployments[], incidents[], reverts[]. Output is Markdown that states, for each
number, how it was measured and on how many records, so a reader can tell an indicative number
from a conclusive one. Standard library only.
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
from datetime import datetime, timezone
from typing import Any, Optional


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


def compute(raw: dict[str, Any], cost_total: Optional[float]) -> dict[str, Any]:
    since = parse_ts(raw.get("since") + "T00:00:00Z" if raw.get("since") and len(raw["since"]) == 10 else raw.get("since"))
    until = parse_ts(raw.get("until") + "T23:59:59Z" if raw.get("until") and len(raw["until"]) == 10 else raw.get("until"))
    days = max(1.0, ((until - since).total_seconds() / 86400.0) if since and until else 30.0)

    prs = raw.get("prs", []) or []
    deployments = raw.get("deployments", []) or []
    incidents = raw.get("incidents", []) or []
    reverts = raw.get("reverts", []) or []

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
    cost_per_pr = (cost_total / len(merged_prs)) if (cost_total is not None and merged_prs) else None

    return {
        "period": {"since": raw.get("since"), "until": raw.get("until"), "days": round(days, 1), "platform": raw.get("platform"), "repo": raw.get("repo")},
        "samples": {"prs": len(merged_prs), "prs_with_size": len(sizes), "deployments": len(deployments), "successful_deployments": len(successful), "incidents": len(incidents), "reverts": len(reverts)},
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
            "cost_total_usd": cost_total,
        },
    }


def load_cost_total(cost_dir: Optional[str]) -> Optional[float]:
    if not cost_dir or not os.path.isdir(cost_dir):
        return None
    total = 0.0
    seen = False
    for name in sorted(os.listdir(cost_dir)):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(cost_dir, name), encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(data, dict):
            # a cost/report.sh summary carries total_cost_usd and its runs_detail: count it once
            if "total_cost_usd" in data:
                total += float(data.get("total_cost_usd") or 0)
                seen = True
            else:
                for row in data.get("runs_detail", []) or []:
                    total += float(row.get("cost_usd") or 0)
                    seen = True
    return total if seen else None


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
    bd = base["dora"] if base else {}
    bc = base["counterweights"] if base else {}
    conclusive = s["deployments"] >= 10 and s["prs"] >= 20
    lines = [
        f"# SDLC metrics: {p.get('repo') or 'repository'} ({p.get('platform') or 'platform'}), {p.get('since')} to {p.get('until')}",
        "",
        f"Sample: {s['prs']} merged PRs, {s['deployments']} deployments ({s['successful_deployments']} successful), {s['incidents']} incidents, {s['reverts']} reverts over {p['days']} days.",
        ("Sample size is large enough to read as a trend." if conclusive else "**Indicative only**: fewer than 10 deployments or 20 PRs. Direction, not magnitude."),
        "",
        "## DORA keys",
        "",
        "| Metric | Value | How measured |",
        "| --- | --- | --- |",
        f"| Deployment frequency | {fmt(d['deployment_frequency_per_week'], ' / week')}{delta(d['deployment_frequency_per_week'], bd.get('deployment_frequency_per_week'), ' / week', False)} | successful production deployments per 7 days |",
        f"| Lead time for changes (p50 / p90) | {fmt(d['lead_time_h_p50'], 'h')} / {fmt(d['lead_time_h_p90'], 'h')}{delta(d['lead_time_h_p50'], bd.get('lead_time_h_p50'), 'h', True)} | first commit (or PR opened) to the first successful deployment after merge; {d['lead_time_samples']} PRs |",
        f"| Change failure rate | {fmt(d['change_failure_rate'], '%')}{delta(d['change_failure_rate'], bd.get('change_failure_rate'), '%', True)} | failed deployments plus deployments whose commit was reverted, over all deployments |",
        f"| Time to restore (MTTR) | {fmt(d['mttr_h'], 'h')}{delta(d['mttr_h'], bd.get('mttr_h'), 'h', True)} | mean of incident open to close, and failed deployment to next success; {d['mttr_samples']} events |",
        "",
        "## Counterweights",
        "",
        "| Metric | Value | How measured |",
        "| --- | --- | --- |",
        f"| Revert rate | {fmt(c['revert_rate'], '%')}{delta(c['revert_rate'], bc.get('revert_rate'), '%', True)} | merged PRs titled Revert over merged PRs |",
        f"| PR size (p50 / p90) | {fmt(c['pr_size_p50'], ' lines', 0)} / {fmt(c['pr_size_p90'], ' lines', 0)}{delta(c['pr_size_p50'], bc.get('pr_size_p50'), ' lines', True)} | additions + deletions; {s['prs_with_size']} of {s['prs']} PRs had size data |",
        f"| Review latency (p50) | {fmt(c['review_latency_h_p50'], 'h')}{delta(c['review_latency_h_p50'], bc.get('review_latency_h_p50'), 'h', True)} | PR opened to first review; {c['review_latency_samples']} PRs |",
        f"| Code churn | {fmt(c['code_churn_lines_per_week'], ' lines / week', 0)}{delta(c['code_churn_lines_per_week'], bc.get('code_churn_lines_per_week'), ' lines / week', True)} | lines changed in merged PRs per 7 days |",
        f"| Defect escape rate | {fmt(c['defect_escape_rate'], '%')}{delta(c['defect_escape_rate'], bc.get('defect_escape_rate'), '%', True)} | incidents over successful deployments |",
        f"| Cost per merged PR | {fmt(c['cost_per_merged_pr_usd'], '$')}{delta(c['cost_per_merged_pr_usd'], bc.get('cost_per_merged_pr_usd'), '$', True)} | agent spend from .sdlc/metrics/cost over merged PRs (total {fmt(c['cost_total_usd'], '$')}) |",
        "",
        "## Reading these numbers",
        "",
        "- Self-reported speed and measured speed frequently diverge. When the team feels faster and lead time or deployment frequency did not move, the measured numbers win.",
        "- A speed metric that improved while a counterweight worsened (larger PRs, more reverts, longer review latency, higher defect escape) is a trade, not a win. Name the trade.",
        "- Compare against the baseline captured before Tier 1 was installed; a period without a baseline is a start, not a result.",
    ]
    return "\n".join(lines) + "\n"


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
    metrics = compute(raw, load_cost_total(args.cost_dir))

    base = None
    if args.baseline:
        with open(args.baseline, encoding="utf-8") as fh:
            base_data = json.load(fh)
        base = base_data if "dora" in base_data else compute(base_data, None)

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
