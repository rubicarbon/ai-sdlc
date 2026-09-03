---
description: "Collect this period's DORA keys and counterweights from the platform, compare with the baseline, and have the metrics analyst write the honest narrative."
disable-model-invocation: true
argument-hint: "[--since YYYY-MM-DD] [--until YYYY-MM-DD]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/metrics/collect.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/cost/report.sh *), Bash(ls .sdlc/metrics *), Bash(jq *)
---

Measure the period, then say what moved. Load `ai-sdlc:sdlc-metrics` for what each number means and when it may be trusted.

1. Collect:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/metrics/collect.sh" $ARGUMENTS
   ```

   Defaults to the last 30 days. It exports through `sdlc-platform metrics_export`, picks the newest `.sdlc/metrics/baseline-*.json` as the baseline, reads `.sdlc/metrics/cost/` for spend, and writes `raw-<since>_<until>.json` and `report-<since>_<until>.md`. Its JSON names `raw`, `report` and `baseline` (`null` when no baseline exists: say so, and point to `/ai-sdlc:sdlc-metrics-baseline`).

2. Spend, when the user asks for it or the report's cost row reads `n/a`: aggregate the Claude Code result files (CI writes them as `sdlc-cost.json`) into the cost directory so the next collect picks them up:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/cost/report.sh" --threshold <cost.alertThresholdUsd> --out .sdlc/metrics/cost/<date>.json --md <result.json>...
   ```

   Exit 1 means the total exceeded the threshold; report that as a finding, not an error.

3. Spawn the `ai-sdlc:sdlc-metrics-analyst` subagent with the Agent tool, giving it the `report`, `raw` and `baseline` paths. Return its narrative unchanged: headline, counterweights, confidence, self-reported versus measured, next measurement.

4. Tell the user to commit the new files under `.sdlc/metrics/`. Done when the report exists and the narrative has been shown.
