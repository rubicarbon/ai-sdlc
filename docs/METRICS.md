# Metrics

`ai-sdlc` measures the loop with the four DORA keys and a set of counterweights, computed by `scripts/metrics/report.py` from a normalised export that `sdlc-platform metrics_export` writes identically on GitHub and Azure DevOps. Every number in a report states how it was measured and on how many records, so a reader can tell an indicative figure from a conclusive one. This document lists the formulas as the code computes them, where the data comes from on each platform, and what the numbers cannot tell you.

## The pipeline

| Step | Script | Output |
| --- | --- | --- |
| Export | `sdlc-platform metrics_export <since> <until> <out.json>` (adapter: `scripts/platform/{github,azure}/metrics_export.sh`) | The normalised file, plus one JSON line of counts |
| Baseline | `scripts/metrics/baseline.sh [--since YYYY-MM-DD] [--platform github\|azure] [--force]` | `.sdlc/metrics/baseline-<date>.json` and `.md` (last 90 days by default) |
| Period report | `scripts/metrics/collect.sh [--since] [--until] [--platform] [--baseline file]` | `.sdlc/metrics/raw-<since>_<until>.json` and `report-<since>_<until>.md` (last 30 days by default) |
| Compute and render | `python report.py raw.json [--baseline file] [--cost-dir DIR] [--out report.md] [--json]` | Markdown, or the computed metrics as JSON with `--json` |
| Narrative | `sdlc-metrics-analyst` agent | Under 300 words: headline, counterweights, confidence, self-reported vs measured, next measurement |

`collect.sh` picks the newest `baseline-*.json` automatically when `--baseline` is not given, and always passes `--cost-dir .sdlc/metrics/cost`. Python 3 is required for `report.py` only; it uses the standard library. `/ai-sdlc:sdlc-metrics-baseline` and `/ai-sdlc:sdlc-metrics-report` are the command names the loop uses for the two scripts.

## What is tracked

All timestamps are parsed as UTC. `days` is the length of the period in days (at least 1; 30 when `since` or `until` is missing). A record is dropped from a metric when the fields the formula needs are missing; it is never counted as zero.

### DORA keys

| Metric | Formula in `compute()` | Records it needs |
| --- | --- | --- |
| Deployment frequency | `successful deployments / days * 7`; `n/a` when there are no deployments at all | `deployments[]` with `status == "success"` |
| Lead time for changes (p50, p90) | For each PR with `merged_at`: start = `first_commit_at`, falling back to `created_at`; end = the first successful deployment whose `finished_at` (fallback `started_at`) is at or after `merged_at`; lead time = `end - start` in hours, kept when non-negative. p50 is the median, p90 the nearest-rank percentile | `prs[].merged_at`, `first_commit_at` or `created_at`, and at least one successful deployment after the merge |
| Change failure rate | `(failed deployments + successful deployments whose sha was reverted) / all deployments`. A deployment counts as reverted when the first 7 characters of its `sha` match the first 7 characters of some `reverts[].reverts_sha` | `deployments[].status`, `deployments[].sha`, `reverts[].reverts_sha` |
| Time to restore (MTTR) | Mean, in hours, over two kinds of event: each incident with both `opened_at` and `closed_at` (close minus open, kept when non-negative), and each failed deployment to the next successful deployment strictly after it | `incidents[]` with both timestamps; `deployments[]` with a failure followed by a success |

Pending deployments (`status == "pending"`) count in the denominator of change failure rate and in the "deployments" sample, but neither as a success nor as a failure.

### Counterweights

| Metric | Formula in `compute()` | Records it needs |
| --- | --- | --- |
| Revert rate | `merged PRs with is_revert / merged PRs` | `prs[].is_revert` (true when the title starts with `Revert`) |
| PR size (p50, p90) | `additions + deletions` per merged PR, only for PRs where both are non-null; median and p90 | `prs[].additions`, `prs[].deletions` |
| Review latency (p50) | `first_review_at - created_at` in hours per merged PR, kept when non-negative; median | `prs[].created_at`, `prs[].first_review_at` |
| Code churn | `sum of PR sizes / days * 7` (lines per week) | Same as PR size |
| Defect escape rate | `incidents / successful deployments` | `incidents[]`, successful `deployments[]` |
| Cost per merged PR | `total cost / merged PRs`, where total cost is the sum over the deduplicated run records read from the `--cost-dir` files | The cost directory (see "Cost tracking" and "Data quality") and at least one merged PR |

The report also prints `cost_total_usd` and the number of run records next to cost per merged PR.

### Samples and the conclusive threshold

Every report starts with the sample line: merged PRs, deployments (successful), incidents, reverts, and the period length. `render()` calls the period conclusive when `deployments >= 10` and `merged PRs >= 20`; otherwise it prints "Indicative only: fewer than 10 deployments or 20 PRs. Direction, not magnitude." The lead time, MTTR and review latency rows each carry their own sample count, and the PR size row says how many PRs had size data, because those metrics often rest on fewer records than the headline sample.

### A worked example

`evals/fixtures/metrics-raw.json` is a 31-day GitHub export with 6 merged PRs, 6 deployments (5 successful, 1 failed), 1 incident and 1 revert. The eval `evals/cases/metrics-report.sh` asserts the numbers `report.py` produces from it:

| Metric | Value | Why |
| --- | --- | --- |
| Deployment frequency | 1.1 / week | 5 successes over 31 days |
| Change failure rate | 33.3% | 1 failed deployment plus 1 successful deployment whose sha was reverted, over 6 |
| Revert rate | 16.7% | 1 of 6 merged PRs is titled `Revert` |
| PR size | 5 of 6 PRs had size data | One PR has `null` additions and deletions; it is reported as missing, not as zero |
| Lead time samples | 6 | Every PR has a successful deployment after its merge; the PR without `first_commit_at` uses `created_at` |
| Cost per merged PR | $0.49 | A cost file totalling 2.95 USD over 6 merged PRs |

The same eval checks that an export with empty arrays renders `n/a` everywhere instead of failing, that `evals/fixtures/metrics-raw-nodeploy.json` (an Azure export with `sources.deployments` set to `not-configured`) renders `source not configured` and no deployment count of 0, and that a cost directory holding an invalid JSON file and a non-numeric cost lists both under "Data quality" while still counting the valid record. `evals/cases/report-python.sh` runs the unit tests in `evals/python/test_report.py`.

## Where the data comes from

Both adapters take `<since>` and `<until>` as `YYYY-MM-DD`, treat them as `T00:00:00Z` and `T23:59:59Z`, and read `metrics.incidentLabel` (default `incident`) and `metrics.deployEnvironment` (default `production`) from `sdlc.config.json`.

### GitHub (`scripts/platform/github/metrics_export.sh`)

| Array | Source | Notes |
| --- | --- | --- |
| `prs` | `gh pr list --state merged --search "merged:<since>..<until>" --limit 500` with `reviews` and `commits` | `first_review_at` is the earliest `submittedAt` among the PR's review events; `first_commit_at` the earliest `committedDate` among its commits; `is_revert` is `title startswith "Revert"` |
| `deployments` | When `github.deployWorkflow` is set: `gh run list --workflow <name> --limit 200`, filtered to the period by `createdAt`; `status` is `success` for conclusion `success`, `pending` while the conclusion is null, `failure` otherwise. Otherwise: the Deployments API (`repos/<repo>/deployments?environment=<env>`, paginated), filtered by `created_at`, with the state of the most recent status per deployment (`success`; `pending`, `in_progress`, `queued` as pending; anything else as failure) | The rendered `sdlc-deploy.yml` writes a deployment record for every production run, so the API path works out of the box at tier 3 |
| `incidents` | `gh issue list --label <incidentLabel> --state all --limit 200`, kept when created on or before `until` and either created on or after `since` or closed on or after `since` (open issues count) | `closed_at` is null while open |
| `reverts` | `git log --since --until --grep '^Revert'` on the local clone; `reverts_sha` is parsed from the body text `reverts commit <sha>` and is null when that phrase is absent | Requires the clone to hold the period's history |

### Azure DevOps (`scripts/platform/azure/metrics_export.sh`)

| Array | Source | Notes |
| --- | --- | --- |
| `prs` | `az repos pr list --status completed --target-branch <repo.defaultBranch> --top 500`, filtered by `closedDate`, capped by `metrics.maxPrs` (default 200) | `first_review_at` is the earliest `publishedDate` among PR threads whose `CodeReviewVoteResult` property is set (the first vote), read through `az rest`. `additions`, `deletions`, `changed_files` and `first_commit_at` are computed from the local clone with `git diff --shortstat` and `git log` between the PR's last merge target and source commits; when either commit is not present locally they are `null` |
| `deployments` | Runs of the deploy pipeline named by `azure.deployPipelineName` (default `sdlc-deploy`) or identified by `azure.deployPipelineId`; `az pipelines runs list --top 200`, filtered by `finishTime` (fallback `queueTime`); `result succeeded` is success, null result is pending, anything else failure; `sha` is `sourceVersion` | When no pipeline is configured or found, the array is empty and stderr says so |
| `incidents` | WIQL: work items in the project whose `System.Tags` contains the incident label and whose `System.CreatedDate` is on or before `until`; `closed_at` is `Microsoft.VSTS.Common.ClosedDate`; kept when opened or closed on or after `since` | The tag is the label; the work item type is not filtered |
| `reverts` | Same `git log` as GitHub | Same requirement on the local clone |

What is `null` on Azure: PR size fields and `first_commit_at` whenever the merge commits are not in the local clone (`pr_get` always returns them as null; only `metrics_export` computes them). The report then excludes those PRs from PR size, churn and, for lead time, falls back to `created_at`. The `repo` field is `<project>/<repo>`.

The Azure adapter is verified against the CLI mocks in `scripts/platform/_mocks`, not against a live organisation, in this build. `scripts/platform/conformance.sh` checks that both adapters produce the same output shape.

### The normalised export schema

From `scripts/platform/contract.md`:

```json
{
  "platform":"github","repo":"owner/name","since":"2026-08-01","until":"2026-09-01","exported_at":"...",
  "prs":[{"id":"77","created_at":"...","merged_at":"...","first_review_at":"...","additions":120,"deletions":8,"changed_files":4,"first_commit_at":"...","author":"login","is_revert":false}],
  "deployments":[{"id":"...","environment":"production","started_at":"...","finished_at":"...","status":"success","sha":"..."}],
  "incidents":[{"id":"...","opened_at":"...","closed_at":"...","labels":["incident"]}],
  "reverts":[{"sha":"...","committed_at":"...","reverts_sha":"..."}]
}
```

`platform` is `github` or `azure`, `status` is `success`, `failure` or `pending`, dates are ISO 8601 UTC, and any field the platform could not supply is `null`. A late baseline additionally carries a top-level `note` string (see below). The export may also carry a top-level `sources` object (source name to status, `not-configured` meaning the source was not measured) and a `warnings` array; "Data quality" under "Cost tracking" describes how the report renders them. `metrics_export` prints one summary line to stdout: `{"prs":n,"deployments":n,"incidents":n,"reverts":n,"out":"<path>","platform":"..."}`.

## Baseline discipline

A baseline is the state of the repository before the loop changed how work flows. It is the only thing a later report can honestly be compared against, so its timing is enforced by `baseline.sh`, not left to memory.

**Before Tier 1.** Capture it right after `/ai-sdlc:sdlc-init` at tier 0, before the first spec, before `REVIEW.md`. The init script's `next_steps` says so in its last line. The default window is the 90 days before today; `--since` widens or narrows it.

**Refusal.** `baseline.sh` exits 1 with `REFUSING to capture a baseline` when any of these is true: `sdlc.config.json` has `tier >= 1`; `REVIEW.md` exists; `docs/agents/issue-tracker.md` exists; any `.sdlc/features/*/publish-manifest.json` exists; a `baseline-*.json` already exists under `.sdlc/metrics/`. It lists every reason it found.

**Late baseline.** `--force` overrides the refusal. The export then gets a top-level `note` reading `LATE BASELINE: captured after the loop was installed (<reasons>)`, the Markdown ends with a "Late baseline" callout telling the reader to treat it as a first period rather than the pre-adoption state, and a warning is printed. When you start at a tier above 0, `next_steps` tells you to run the baseline once with `--force` for exactly this reason.

A baseline file can be either a raw export or the `--json` output of a previous report: `report.py` detects a `dora` key and otherwise computes the baseline from the raw export.

## How to read a report honestly

The rendered report ends with three sentences under "Reading these numbers". They are the reading rules:

1. **Indicative vs conclusive.** Fewer than 10 deployments or 20 merged PRs in the period means direction, not magnitude. The analyst agent is told to stop after stating that. A metric row with a sample count of 2 is a story about two records.
2. **Speed against counterweights.** Every DORA delta is printed with `better` or `worse`. When a speed metric improved (deployment frequency up, lead time down) and a counterweight worsened (PR size up, revert rate up, review latency up, defect escape up, cost per PR up), that is a trade, not a win. Name the trade. The analyst agent is instructed to look for exactly this pairing.
3. **Self-reported vs measured.** Teams frequently report feeling faster while lead time and deployment frequency did not move. When they disagree, the measured numbers win. The artifact that usually settles it is cycle time per ticket, which this report does not compute.
4. **Compare only against your own baseline.** Deltas are shown only when a baseline was given. A period without a baseline is a start, not a result. Do not compare across repositories: deployment counting (workflow runs vs Deployments API vs pipeline runs), review conventions and incident labelling differ per repo, so the same formula yields incomparable numbers.
5. **Null is not zero.** A PR without size data leaves PR size and churn; a deployment without a successor leaves MTTR; an incident without `closed_at` leaves MTTR but still counts toward defect escape. The row's sample count tells you how much of the headline sample the row actually used.

## Cost tracking

Agent spend is tracked per CI run and aggregated into cost per merged PR.

**Where it is produced.** The rendered `sdlc-pr-review` workflow (GitHub) and pipeline (Azure) both end by writing `sdlc-cost.json`:

```json
{"run_id":"...","pr":123,"total_cost_usd":1.42,"num_turns":18,"recorded_at":"2026-09-01T10:00:00Z"}
```

GitHub reads the cost from the `claude-code-action` execution file; Azure from the `claude -p --output-format json` result. Both publish the file as a build artifact named `sdlc-cost-<run id>` and fail the job when the run's cost exceeds `cost.maxBudgetUsd` (the same value passed as `--max-budget-usd`, alongside `--max-turns` from `cost.maxTurns`).

**Weekly alert (GitHub only).** `sdlc-cost-report.yml` runs every Monday, downloads the last 7 days of `sdlc-cost-*` artifacts, writes a table to the step summary, and opens or updates an issue labelled `sdlc-cost` when the total exceeds `cost.alertThresholdUsd`. No equivalent pipeline is rendered for Azure; use `cost/report.sh` on the published artifacts instead.

**Local aggregation.** `scripts/cost/report.sh [--threshold USD] [--out file.json] [--md] <result.json>...` accepts three shapes: a `claude -p --output-format json` result, a `claude-code-action` execution file (an array with a `{type:"result"}` entry), and the `sdlc-cost.json` records above. It prints a summary (`runs`, `total_cost_usd`, `avg_cost_usd`, `max_cost_usd`, `total_turns`, `threshold_usd`, `over_threshold`, `skipped`, `runs_detail`) or a Markdown table with `--md`, and exits 1 when the total exceeds `--threshold`, so a pipeline step can fail on it. Each `runs_detail` row carries `file`, `cost_usd`, `turns`, `duration_ms`, `recorded_at`, `pr`, `run_id`, `session_id` and `session` (`session_id`, else `run_id`; kept for older consumers). Input files that are missing or not valid JSON of one of the three shapes are listed by path under `skipped` and noted on stderr; they never change the exit code, and a summary with a non-empty `skipped` list is telling you that spend was dropped.

**Cost per merged PR.** `report.py --cost-dir` reads every `.json` file in the directory and reduces each one to canonical run records before summing, so a run that appears in several files (a raw result plus a weekly summary built from it, or the same artifact downloaded twice) is counted once. The deduplicated total is divided by merged PRs in the period, and the report prints the total and the number of run records next to the value. `collect.sh` always uses `.sdlc/metrics/cost/`, and both `baseline.sh` and `collect.sh` create that directory. Nothing moves CI artifacts into it automatically: download the `sdlc-cost-*` artifacts for the period (or run `cost/report.sh --out .sdlc/metrics/cost/<period>.json` over them) before collecting, otherwise cost per merged PR is `n/a`.

Cost per merged PR is a counterweight, not a target. A falling cost with a rising change failure rate is the trade to name.

### Data quality

`report.py` prints a "Data quality" section in the Markdown, and a `data_quality` object in the `--json` output (`{"warnings": [...], "cost_records": N, "cost_files": N}`), whenever there is anything to say: a source that is not configured, a warning from the export, or a cost file it could not use. A report without that section had nothing to report.

**Canonical run records.** Every file in `--cost-dir` is reduced to run records as follows. A dict with a `runs_detail` array (a `cost/report.sh` summary) contributes its detail rows and never its own `total_cost_usd`. Any other dict is one record (a `claude -p --output-format json` result or an `sdlc-cost.json` record). A list (a `claude-code-action` execution file) contributes its `{"type":"result"}` entries. Files whose name does not end in `.json` are ignored.

**Dedup keys.** Records are keyed by `run_id`, else `session_id` (a summary row's `session` field carries the same value), else the composite fallback `<cost_usd>|<num_turns>|<recorded_at>|<pr>`, with the cost printed to 6 decimals, a missing `num_turns` read as 0 and a missing `recorded_at` or `pr` as an empty string, so a raw record and the summary row `report.sh` wrote for the same id-less run agree. The first occurrence in file-name order wins. Two id-less runs with identical cost, turns, timestamp and PR therefore collapse into one, and the warning list says how many records were counted once because they appeared more than once. `evals/python/test_report.py` covers raw-only, summary-only, mixed, duplicated and fallback directories.

**Warnings for malformed files.** A file that is not valid JSON, a record whose cost is not a number (`"abc"`), a dict with neither `total_cost_usd` nor `cost_usd`, an execution file without a result entry, a `runs_detail` that is not a list, or a top-level value that is neither an object nor a list each produce a `cost: <file>: <reason>` warning. The other files are still counted; nothing is skipped silently. `cost_files` is the number of `.json` files examined and `cost_records` the number of canonical records that survived deduplication.

**Sources and warnings in the export.** The export may carry `"sources": {"prs": "ok", "deployments": "not-configured", "incidents": "ok", "reverts": "partial"}` and `"warnings": ["..."]`, written by the adapter when a data source could not be read as configured. `report.py` treats `sources.<name> == "not-configured"` as "this was not measured", never as zero: with `deployments` not configured, deployment frequency, lead time, change failure rate and defect escape rate render as `source not configured` (and are `null` in the JSON, with `samples.deployments` also `null`), the sample line reads `deployments: source not configured`, and the indicative sentence says why. With `incidents` not configured, defect escape rate is unavailable. `reverts` or `prs` not configured produce a warning line instead, because change failure rate still has its failed-deployment half and nothing else can stand in for PRs. Any other status than `ok` (`partial`, for example) becomes an `export: <name>: source status is <status>` warning, and every entry of `warnings[]` is carried into the section prefixed `export:`. Deployments present in an export whose `sources.deployments` says `not-configured` are ignored with a warning rather than trusted. An export without these keys is treated exactly as before: empty arrays render `n/a`, and the sample line shows the counts.

## Limitations

These follow from the code and hold on both platforms unless stated.

- **Deployment attribution is by time, not by commit lineage.** Lead time pairs a PR with the first successful deployment at or after its merge time, regardless of whether that deployment contained the PR's commit. A hotfix deployed minutes after an unrelated merge shortens that merge's lead time. Change failure rate matches reverts to deployments by the first 7 characters of the sha, so it needs the deployment record to carry the deployed sha; deployments without a sha can never be counted as reverted.
- **First review is the first review event, or the first vote thread.** On GitHub `first_review_at` is the earliest review submission of any state (approve, request changes, comment). On Azure it is the earliest thread carrying a `CodeReviewVoteResult` property, so comment-only threads before the first vote do not count. Review latency therefore measures slightly different things on the two platforms.
- **Reverts are detected by text.** A PR is a revert when its title starts with `Revert`; a revert commit is one whose subject starts with `Revert` and whose body contains `reverts commit <sha>` (the format `git revert` writes). Reverts done by hand, squashed under another title, or rolled forward as a fix are invisible to revert rate and to the revert part of change failure rate.
- **Incidents are whatever carries the label.** An issue or work item tagged `metrics.incidentLabel` is an incident; nothing checks severity or that it was a production event. MTTR for incidents is open-to-close time, which includes the time until someone closed the ticket.
- **Deployments depend on configuration.** GitHub counts workflow runs when `github.deployWorkflow` is set and Deployments API records otherwise; Azure counts runs of one pipeline. Runs of that workflow or pipeline that did not deploy (cancelled, staging only) still count when the platform reports them as a completed run with a result. An unconfigured Azure deploy pipeline is a source that is not configured, not a period without deployments: the adapter reports `sources.deployments` as `not-configured`, and the report renders deployment frequency, lead time, CFR and defect escape as `source not configured` rather than as a measured zero or a plain `n/a` (see "Data quality").
- **Azure size data needs the local clone.** PR additions, deletions, changed files and first commit time exist only when both merge commits are present locally; a shallow clone or a clone that predates the PR yields nulls, and the report says how many PRs lacked size data.
- **Result limits.** GitHub reads at most 500 merged PRs, 200 workflow runs and 200 incident issues per export; Azure at most 500 completed PRs (then `metrics.maxPrs`, default 200), 200 pipeline runs. Long periods on busy repositories are truncated silently.
- **Percentiles are nearest-rank.** p90 is the value at the rounded 90 percent position of the sorted list, not an interpolation; with few samples it is often the maximum.
- **Cost covers CI runs only.** Interactive sessions on a developer's machine leave no `sdlc-cost.json` unless someone saves the `claude -p` result into the cost directory by hand. Cost per merged PR is therefore a lower bound on agent spend.
