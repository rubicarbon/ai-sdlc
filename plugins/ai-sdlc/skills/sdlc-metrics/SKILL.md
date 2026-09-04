---
name: sdlc-metrics
description: "How ai-sdlc measures delivery: baseline, collect and report scripts, the DORA definitions as implemented, the counterweights, and the rules for reading small samples honestly. Use when asked how the team is doing, whether the loop made things faster, what a metric means, or before running the metrics commands."
---

# Metrics

Three scripts, one Python renderer, no LLM in the numbers. The narrative comes afterwards from the `sdlc-metrics-analyst` agent.

| Script | Does | Writes under `.sdlc/metrics/` |
| --- | --- | --- |
| `scripts/metrics/baseline.sh [--since] [--platform] [--force]` | exports the 90 days before the loop was installed; refuses once Tier 1 artifacts exist (tier 1 or above, `REVIEW.md`, `docs/agents/issue-tracker.md`, published features, an existing baseline) unless `--force`, which stamps `LATE BASELINE` into the JSON and the report | `baseline-<date>.json`, `baseline-<date>.md` |
| `scripts/metrics/collect.sh [--since] [--until] [--platform] [--baseline]` | exports the period (default 30 days), picks the newest baseline, reads `cost/` for spend, renders the report | `raw-<since>_<until>.json`, `report-<since>_<until>.md` |
| `scripts/metrics/report.py raw.json [--baseline f] [--cost-dir d] [--out f] [--json]` | computes and renders; `--json` prints the numbers instead of Markdown | the report |
| `scripts/cost/report.sh [--threshold USD] [--out f] [--md] <result.json>...` | sums Claude Code result files; exit 1 over the threshold; unreadable inputs are listed under `skipped` in the summary and must be reported, never ignored | `cost/<name>.json` when `--out` points there |

Both exports go through `sdlc-platform metrics_export <since> <until> <out>`, so the raw file has the same shape on GitHub and Azure DevOps: `prs[]`, `deployments[]`, `incidents[]`, `reverts[]`. Python 3 is required for these scripts only.

## DORA keys, as `report.py` computes them

| Metric | Definition in code | Needs |
| --- | --- | --- |
| Deployment frequency | successful deployments divided by period days, times 7 | `deployments[].status == success` |
| Lead time for changes | per merged PR: `first_commit_at` (fallback `created_at`) to the first successful deployment at or after `merged_at`; p50 (median) and p90 reported | PRs with `merged_at` and a later deployment |
| Change failure rate | failed deployments plus successful deployments whose sha appears in `reverts[].reverts_sha`, over all deployments | deployments; reverts from `git log --grep '^Revert'` |
| Time to restore (MTTR) | mean of: incident `opened_at` to `closed_at` for closed incidents, and failed deployment to the next successful deployment | incidents labelled `metrics.incidentLabel`; failed deployments |

Deployments come from the Deployments API or the configured deploy workflow (GitHub) and the configured deploy pipeline (Azure), filtered to `metrics.deployEnvironment`.

## Counterweights

Speed without these is a trade, not a win. Each row of the report says how it was measured and on how many records.

| Metric | Definition in code |
| --- | --- |
| Revert rate | merged PRs with `is_revert` over merged PRs |
| PR size (p50 / p90) | additions plus deletions per merged PR; Azure supplies these only when computed from local git, otherwise the PR is excluded from the sample |
| Review latency (p50) | PR `created_at` to `first_review_at` |
| Code churn | total lines changed per week |
| Defect escape rate | incidents over successful deployments (each postmortem's escaped stage names where it should have stopped) |
| Cost per merged PR | total from `cost/` over merged PRs, after every file is reduced to canonical run records deduplicated by `run_id`, then `session_id`, then a documented composite key (a `report.sh` summary contributes its `runs_detail` rows, never also its total); `n/a` until cost files exist; malformed files appear in the report's Data quality section |

## Honesty rules

1. Below 10 deployments or 20 merged PRs in the period the report prints `Indicative only`. Read the direction, not the magnitude, and say so.
2. Measured beats self-reported. When the team feels faster and lead time or deployment frequency did not move, the measured numbers win; suggest the artifact that would settle it (cycle time per ticket).
3. A late baseline (`--force`) is a first period, not the pre-adoption state. Every comparison against it says `late baseline`.
4. A speed metric that improved while a counterweight worsened is reported as a trade, with both numbers side by side.
5. Deltas against the baseline are shown only where both sides have a value; `n/a` stays `n/a`.
6. No praise, no blame: systems and signals only. Keep the narrative under 300 words, numbers in tables.
7. A source that is not configured (for example no deploy pipeline on Azure) is reported as `source not configured`, never as zero deployments; the report's Data quality section and the export's `sources` and `warnings` fields say which.

Commands: `/ai-sdlc:sdlc-metrics-baseline` before Tier 1, `/ai-sdlc:sdlc-metrics-report` each period.
