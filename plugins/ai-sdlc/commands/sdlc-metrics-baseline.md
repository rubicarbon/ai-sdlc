---
description: "Capture the pre-adoption metrics baseline (last 90 days of PRs, deployments, incidents, reverts) before Tier 1 changes how the team works, then have the metrics analyst read it."
disable-model-invocation: true
argument-hint: "[--since YYYY-MM-DD] [--force]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/metrics/baseline.sh *), Bash(jq *)
---

Record what the numbers looked like before the loop, so later reports have something honest to compare against. Load `ai-sdlc:sdlc-metrics` for the definitions.

1. Run the export:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/metrics/baseline.sh" $ARGUMENTS
   ```

   Default window is the 90 days before today; `--since` moves the start. It writes `.sdlc/metrics/baseline-<date>.json` and `baseline-<date>.md` and prints `{raw, report, since, until}`.

2. When it exits 1 with `REFUSING to capture a baseline`, show its reasons verbatim (tier is 1 or above, `REVIEW.md` exists, `docs/agents/issue-tracker.md` exists, features published, a baseline already exists). Explain: a baseline taken after the loop is installed measures the loop, not the state before it. Offer `--force` with AskUserQuestion only if the user did not already pass it; pass it only on an explicit yes. A forced run stamps `note: LATE BASELINE` into the JSON and a `Late baseline` paragraph into the report, and every later comparison inherits that label.

3. Hand the report to the analyst: spawn the `ai-sdlc:sdlc-metrics-analyst` subagent with the Agent tool, giving it the `report` and `raw` paths and the instruction that this is a baseline (no comparison, describe the starting point and the sample size). Return its narrative to the user unchanged.

4. Tell the user to commit `.sdlc/metrics/baseline-<date>.*`. Done when the files exist and the narrative has been shown, or when the refusal and its reasons have been explained and the user declined `--force`.
