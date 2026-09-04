# Adopting ai-sdlc

This is the order in which to switch the loop on, what each step changes, what to measure after it, and how to get out again. Every step below is something the code does today; nothing is aspirational. Where a step is a command only a human can type, it is written as `/ai-sdlc:<name>` or `/mattpocock-skills:<name>`; skills the agent calls itself are written as `ai-sdlc:<name>` or `mattpocock-skills:<name>`.

The loop is grill, spec, tickets, build, review, verify, ship, learn. Each stage commits an artifact the next stage reads. Nothing is implemented without an accepted ticket, and nothing merges without a human at the gate. The tiers below add those constraints one layer at a time so the team can feel each one before the next arrives.

| Tier | Name | What `/ai-sdlc:sdlc-init` renders |
| --- | --- | --- |
| 0 | Foundation | A managed block in `CLAUDE.md`, an empty `CONTEXT.md` seed, `docs/agents/domain.md`, deny rules in `.claude/settings.json` (secrets, force push, the config file), marker lines in `.gitignore`, `sdlc.config.json`, `.sdlc/managed-files.json` |
| 1 | Artifacts | `REVIEW.md`, `docs/agents/issue-tracker.md` (GitHub or Azure), the `.sdlc/` tree (`features/`, `verify/`, `releases/`, `postmortems/`, `metrics/cost/`), `docs/adr/` |
| 2 | Guardrails | `guardrails.requireTicket` defaults to on; the next-steps list tells you to run `sdlc-platform branch_protect_apply <default-branch>` |
| 3 | Automation | CI files (`.github/workflows/sdlc-*.yml` or `.azuredevops/pipelines/sdlc-*.yml`), a PR template, `CODEOWNERS` (GitHub) or `branch-policies.json` (Azure), and the cost caps `cost.maxTurns`, `cost.maxBudgetUsd`, `cost.alertThresholdUsd` written into the CI files |

Rendering is cumulative: tier 3 always includes tiers 0 to 2. The hooks (`guard-secrets`, `guard-protected-paths`, `guard-test-edits`, `guard-verifier-readonly`, `guard-ticket-gate`, `gate-production`, `post-edit-verify`) ship with the plugin and are active at every tier; they exit silently in any repository without `sdlc.config.json`, and the ticket gate is off below tier 2 unless `guardrails.requireTicket` is set.

## Week 1: solo pilot at tier 0

Pick one repository and one person. The goal of the week is one feature through the whole loop, not a rollout.

### Day 1: install both plugins

`ai-sdlc` does not contain the inner development loop. That is the `mattpocock-skills` plugin from Claude Code's official marketplace, and `docs/REUSE.md` maps every one of its skills to the point where this plugin picks up.

```
/plugin install mattpocock-skills
/plugin marketplace add rubicarbon/ai-sdlc
/plugin install ai-sdlc@ai-sdlc-kit
```

Restart Claude Code after installing. The plugin's `bin/` directory puts the `sdlc-platform` command on your PATH while the plugin is enabled. Runtime dependencies are `bash`, `git` and `jq`, plus `gh` (GitHub) or `az` with the `azure-devops` extension (Azure DevOps). `python3` is needed only for the metrics report.

### Day 1: initialise at tier 0

```
/ai-sdlc:sdlc-init
```

The command drives `scripts/init/run.sh`, which detects the platform from the git remote, the verify command from the project, and whether `mattpocock-skills` is installed. Start at tier 0 even if you intend to reach tier 3: the baseline (next step) can only be captured while the repository is still at tier 0.

The script prints one JSON object with `result`, `files`, `pending`, `user_edited` and `next_steps`. Read `next_steps`; it is generated from what the script actually found (missing `gh auth login`, missing `az extension add --name azure-devops`, an editable copy of the upstream skills that would load every skill twice, and so on). Re-running is safe: a clean re-run prints `result: "already-initialised"` and writes nothing. Every rendered file is tracked by hash in `.sdlc/managed-files.json`, so later runs can tell an unchanged file from one the template changed from one you edited; user-edited files are reported and never overwritten without `--force`.

Commit the rendered files.

### Day 1: capture the baseline before anything else

The last item in `next_steps` at tier 0 says to capture the metrics baseline now. Do it before the first spec, before `REVIEW.md` exists, before the tier changes:

```
/ai-sdlc:sdlc-metrics-baseline
```

or directly:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/metrics/baseline.sh" [--since YYYY-MM-DD]
```

It exports the last 90 days through `sdlc-platform metrics_export` to `.sdlc/metrics/baseline-<date>.json` and renders `baseline-<date>.md`. It refuses to run once any Tier 1 artifact exists (tier 1 or above in the config, `REVIEW.md`, `docs/agents/issue-tracker.md`, a published feature, or an existing baseline), because a baseline taken after the change is not a baseline. `--force` records a late snapshot and labels it as such in both files. `docs/METRICS.md` explains why this ordering matters.

### Days 2 to 5: one feature through the loop

Run one real, small feature end to end. Ask `ai-sdlc:sdlc-loop` at every step; it checks the artifacts with `scripts/loop/precondition.sh`, not memory, and tells you which artifact is missing and what produces it.

| Step | Who types it | What must exist afterwards |
| --- | --- | --- |
| `/ai-sdlc:sdlc-start <one line>` | you | Terms in `CONTEXT.md`, ADRs under `docs/adr/` (it calls `mattpocock-skills:grilling` and `mattpocock-skills:domain-modeling`) |
| `/mattpocock-skills:to-spec` | you | `spec.md` in a feature directory (`.scratch/<slug>/` is their layout; `.sdlc/features/<slug>/` is ours; both are recognised) |
| `/mattpocock-skills:to-tickets` | you | `issues/NN-<slug>.md` with `Blocked by:` lines and `Status: ready-for-agent` |
| `/ai-sdlc:sdlc-publish <feature-dir>` | you | Tracker ids written back as the first line of each file, `publish-manifest.json`. Preview with `--dry-run`. Skipped when `platform` is `none` |
| write `.sdlc/ACTIVE_TICKET`, then `/mattpocock-skills:implement` on a branch | you | Commits referencing the ticket id |
| `mattpocock-skills:code-review` | the agent, via the Skill tool | Review notes |
| `/ai-sdlc:sdlc-verify` | you | `.sdlc/verify/<date>-<sha>.md` with a `**Verdict:**` line, written by the read-only `sdlc-verifier` subagent in a fresh context |
| `sdlc-platform pr_create <title> <body-file> <base> <head>` | the agent | The PR; a human approves it |

At tier 0 the ticket gate is off, so writing `.sdlc/ACTIVE_TICKET` is a habit you are building for tier 2, not yet an enforced rule. Delete the file when the PR is opened.

What to measure at the end of week 1: did every stage leave its artifact, and where did you route around the loop? Write those two answers down; they decide the tier 1 configuration.

## Weeks 2 to 4: tiers 1 and 2

### Tier 1: artifacts

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init/run.sh" --tier 1
```

(`/ai-sdlc:sdlc-init` is the interactive front for the same script; every flag below is a `run.sh` flag). This renders `REVIEW.md`, the platform's `docs/agents/issue-tracker.md`, the `.sdlc/` tree and `docs/adr/`. Once `REVIEW.md` exists the baseline script refuses; that is the point.

`docs/agents/issue-tracker.md` is the file the upstream skills read to learn how to publish, fetch and link tickets. Ours routes every operation through `sdlc-platform`, which is what makes `to-spec` and `to-tickets` publish to Azure Boards natively (blocking edges become Successor links). If you later run `/mattpocock-skills:setup-matt-pocock-skills`, answer "Other" for the tracker and keep this file, or skip the tracker section; `next_steps` says the same when the platform is Azure.

### Tune REVIEW.md

`REVIEW.md` is rendered from a template with `review.requiredApprovals` and `review.nitCap` filled in. It defines the three severities (Blocking, Important, Nit with a cap), the human-only areas (authentication, authorisation, cryptography, payments, billing), the security check list and the standards. Both `mattpocock-skills:code-review` and the `sdlc-security-auditor` subagent rank against it, and findings are advisory: a human approves.

Edit it freely. It is a managed file, so `run.sh` will report it as `user-edited` on later runs and keep your version unless you pass `--force`. Two tunings pay off early: adjust the nit cap to what your reviewers actually read, and extend the human-only areas to whatever your repository must not let an agent author.

### Tier 2: guardrails

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init/run.sh" --tier 2
```

Two things change. `guardrails.requireTicket` now defaults to on, and `next_steps` tells you to protect the default branch:

```
sdlc-platform branch_protect_apply main
```

On GitHub this applies the rendered `branch-protection.json`: code-owner reviews required, `review.requiredApprovals` approving reviews, stale reviews dismissed, conversation resolution required, force pushes and deletions blocked, and `github.requiredChecks` as required status checks. On Azure it applies branch policies, and the required-reviewer policy needs `azure.requiredReviewers` in the config because Azure Repos has no CODEOWNERS; without it that policy is reported under `skipped`. The call is idempotent and prints `applied`, `unchanged` and `skipped`.

### Two habits the hooks now enforce

**ACTIVE_TICKET.** With `requireTicket` on, `guard-ticket-gate` denies `Edit`, `Write` and `NotebookEdit` on source files until `.sdlc/ACTIVE_TICKET` names the ticket being built. Documentation, `.md`, `.txt`, `docs/**`, `.claude/**`, the artifacts directory and anything in `guardrails.ticketFreePaths` stay editable so the earlier stages can run.

```
printf '%s\n' "<ticket-id>" > .sdlc/ACTIVE_TICKET
```

Take the id from the ticket file's first line (`<!-- sdlc-publish: id=... -->`) or from the tracker, confirm with `sdlc-platform work_item_get <id>` that its blockers are `closed`, and delete the file when the PR is opened.

**FIX_MODE.** Bug fixes follow `mattpocock-skills:diagnosing-bugs`. Once the regression test is red and committed, arm the test guard:

```
touch .sdlc/FIX_MODE
```

While the marker exists, `guard-test-edits` denies edits to files matching `guardrails.testGlobs` (defaults cover `*.test.*`, `*.spec.*`, `__tests__/`, `tests/`, `fixtures/` and more), so the fix cannot pass by changing the test. `rm .sdlc/FIX_MODE` after the fix is green. Both markers are in `.gitignore` from tier 0.

**Protected paths.** `guard-protected-paths` denies changes to `guardrails.protectedPaths` (defaults: CI files, `CODEOWNERS`, `sdlc.config.json`, `.claude/settings.json`, lockfiles) and to `.sdlc/release/**`. A human unlocks a one-off change by creating `.sdlc/UNLOCK_PROTECTED`; the marker itself is protected, so the agent cannot create it. Delete it afterwards.

What to measure at the end of week 4: how often a hook denied something, and whether each denial was the loop working or the configuration being wrong. Denials on files that should be ticket-free go into `guardrails.ticketFreePaths`; denials on tests that really were wrong are the `rm .sdlc/FIX_MODE`, edit, re-arm path, and should be rare.

## From solo pilot to a small team

### When to switch

Switch `team.mode` from `solo` to `team` at the first of these:

- A second contributor starts running the loop in the same repository.
- The first agent-authored PR is reviewed by someone other than the person who drove the agent.
- The first incident traced to a change that went through the loop. Write the postmortem first (`.sdlc/postmortems/`, template under `templates/artifacts/postmortem.md.tmpl`), then switch.

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init/run.sh" --team team
```

### What team mode changes

| Change | Where it lands | Condition |
| --- | --- | --- |
| `team.enablePluginForTeam` is set to `true` and `settings.team.json.tmpl` is merged into `.claude/settings.json`: `extraKnownMarketplaces` for `ai-sdlc-kit` and `enabledPlugins` for `ai-sdlc@ai-sdlc-kit` and `mattpocock-skills@claude-plugins-official` | `.claude/settings.json` | `team.mode` is `team` and `team.enablePluginForTeam` is `true` (the default `run.sh` writes for team mode) |
| `next_steps` adds "Commit .claude/settings.json: teammates get ai-sdlc and mattpocock-skills enabled automatically." | init output | `team.mode` is `team` |
| `team.codeowners` and `team.securityOwners` default to `@<repo owner>` | `sdlc.config.json` | Written at init; edit them to real teams before tier 3 |

Settings are merged, never clobbered: `merge-settings.sh` combines the fragments with whatever is already in `.claude/settings.json`.

Two things people expect from team mode actually come with tier 3, not with the mode switch: `CODEOWNERS` (GitHub only; every path owned by `team.codeowners`, human-only areas additionally by `team.securityOwners`, and the SDLC configuration files owned by `team.codeowners`) and the PR template with its authorship disclosure section (two checkboxes: which parts were agent-written, and that no human-only area was agent-authored or a human adopted it in a review comment). The disclosure is what lets a reviewer who did not drive the agent know where to look.

## Tier 3: automation

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init/run.sh" --tier 3
```

Before running it, set `cost.maxTurns`, `cost.maxBudgetUsd` and `cost.alertThresholdUsd` in `sdlc.config.json` (the example config uses 40 turns, 5 USD per run, 25 USD per week); they are substituted into the CI files. Then follow `next_steps`: commit the CI files, register them with `sdlc-platform ci_workflow_install`, create `scripts/deploy.sh <environment> <sha>`, and run the setup wizard `/ai-sdlc:sdlc-init` generates at `scripts/sdlc-setup-wizard.sh` for the `ANTHROPIC_API_KEY` secret and the production approval rule.

| File | GitHub | Azure | What it does |
| --- | --- | --- | --- |
| PR review | `sdlc-pr-review.yml` | `sdlc-pr-review.yml` | Runs Claude Code on every PR with `--max-turns` and `--max-budget-usd` from the config, loads `ai-sdlc:sdlc-security-review`, posts an advisory comment ranked per `REVIEW.md` plus a spec-compliance section, records `sdlc-cost.json` as a build artifact, and fails the job when the run cost exceeds `cost.maxBudgetUsd`. Read-only tools only. |
| Evals | `sdlc-evals.yml` | `sdlc-evals.yml` | Weekly and on config changes: validates `sdlc.config.json` against the schema, runs `run.sh --check` for drift, runs the plugin's own `evals/run.sh`, and runs shellcheck |
| Deploy | `sdlc-deploy.yml` | `sdlc-deploy.yml` | Staging automatically, production behind the platform's environment approval (GitHub environment `production` reviewers; Azure environment Approvals check). GitHub records each production run through the Deployments API; Azure runs of this pipeline are what `metrics_export` counts as deployments |
| Cost report | `sdlc-cost-report.yml` | not rendered | Weekly: sums the last 7 days of `sdlc-cost-*` artifacts and opens or updates an issue labelled `sdlc-cost` when the total crosses `cost.alertThresholdUsd` |

The deploy gate on the agent's side is `gate-production`: any `Bash` or `PowerShell` command matching `environments.prod.deployCommandPatterns` (defaults include `git push * main`, `gh workflow run *deploy*`, `az pipelines run *`, `kubectl apply *`, `helm upgrade *`, `terraform apply *`) is denied unless `.sdlc/release/AUTHORIZED-<HEAD sha>` exists and has not expired. That file is written by `scripts/ship/authorize.sh`, which refuses to run inside a Claude Code session and must be run by a human in their own terminal:

```
bash <plugin-root>/scripts/ship/authorize.sh [--sha HEAD] [--ttl-minutes 120]
```

`/ai-sdlc:sdlc-ship` is the stage that asks for it. The agent never holds production credentials, and the marker directory is a protected path.

What to measure after tier 3: the CI review cost per PR (the step summary of every `sdlc-pr-review` run, and the weekly cost report), how many review comments were acted on, and whether the evals workflow ever went red on drift. Drift means the plugin's templates moved; `run.sh --upgrade` applies the change, `--force` also overwrites user-edited files.

## What to measure, and when to stop

Run the report every period from tier 1 on:

```
/ai-sdlc:sdlc-metrics-report
```

or `bash "${CLAUDE_PLUGIN_ROOT}/scripts/metrics/collect.sh" [--since] [--until]`. It writes `.sdlc/metrics/raw-<since>_<until>.json` and `report-<since>_<until>.md`, uses the newest `baseline-*.json` as the baseline, and reads `.sdlc/metrics/cost/` for cost per merged PR. The `sdlc-metrics-analyst` agent turns the report into a short narrative. `docs/METRICS.md` documents every formula.

| After | Look at | Keep going when | Stop or step back when |
| --- | --- | --- | --- |
| Week 1 | Did each stage leave its artifact | Yes, and the spec and tickets were read by the later stages | You routed around three or more stages to get the feature out |
| Tier 1 | Review latency, PR size | Latency flat or down, size flat or down | PR size p50 grows while lead time does not fall: the loop is producing bigger, slower changes |
| Tier 2 | Hook denials per week, revert rate | Denials fall as habits form; reverts flat or down | Denials stay high after four weeks and most are configuration, or `UNLOCK_PROTECTED` becomes routine |
| Tier 3 | Cost per merged PR, review findings acted on, CFR | Cost per PR is stable and comments change code | Cost per PR climbs with no change in CFR or defect escape, or the weekly cost issue stays open |
| Any period | Self-reported speed vs measured lead time and deployment frequency | They agree | The team feels faster and the measured numbers did not move. The measured numbers win |

The report marks any period with fewer than 10 deployments or 20 merged PRs as indicative only. Do not make tier decisions on an indicative period. Do not compare across repositories.

Stepping back is a config change: lower `tier` in `sdlc.config.json` and re-run init. Rendered files from the higher tier are not deleted; remove them by hand or leave them.

## Day-to-day command cheat sheet

Only a human can type the slash commands. The agent calls the Skill-tool names.

| Task | Command |
| --- | --- |
| What comes next | ask `ai-sdlc:sdlc-loop`, or `/ai-sdlc:sdlc-status` |
| Frame a change | `/ai-sdlc:sdlc-start <one line>` (calls `mattpocock-skills:grilling`, `mattpocock-skills:domain-modeling`) |
| Big change, many sessions | `/mattpocock-skills:wayfinder` |
| Non-code plan | `/mattpocock-skills:grill-me` |
| Write the spec | `/mattpocock-skills:to-spec` |
| Cut tickets | `/mattpocock-skills:to-tickets` |
| Push spec and tickets to the tracker | `/ai-sdlc:sdlc-publish <feature-dir> [--dry-run]` |
| Start building | `printf '%s\n' "<id>" > .sdlc/ACTIVE_TICKET`, then `/mattpocock-skills:implement` on a branch |
| Test-first | `mattpocock-skills:tdd` (agent) |
| Bug fix | `mattpocock-skills:diagnosing-bugs` (agent), then `touch .sdlc/FIX_MODE` until green |
| Review the diff | `mattpocock-skills:code-review` (agent) |
| Verify in a fresh context | `/ai-sdlc:sdlc-verify [spec-or-ticket] [--base <ref>] [--security]` |
| Security review only | `ai-sdlc:sdlc-security-review` (agent), `sdlc-security-auditor` subagent |
| Platform operations | `sdlc-platform <function> [args]`; `--dry-run` to preview; see `ai-sdlc:sdlc-platform` |
| Open the PR | `sdlc-platform pr_create <title> <body-file> <base> <head>` |
| Checks | `sdlc-platform pr_checks <id>` (exit 8 while pending) |
| Ship | `/ai-sdlc:sdlc-ship`; a human runs `authorize.sh` in their own terminal |
| Learn | `/ai-sdlc:sdlc-postmortem`, `/ai-sdlc:sdlc-metrics-report` |
| Baseline (tier 0 only) | `/ai-sdlc:sdlc-metrics-baseline` |
| Cost of agent runs | `bash <plugin-root>/scripts/cost/report.sh [--threshold USD] [--md] <result.json>...` |
| Merge conflicts | `mattpocock-skills:resolving-merge-conflicts` (agent) |
| Hand over a session | `/mattpocock-skills:handoff` |
| Triage issues | `/mattpocock-skills:triage` |
| Check the upstream plugin still matches the routing table | `bash <plugin-root>/scripts/reuse/check-mattpocock.sh` |
| Check rendered files for drift | `bash <plugin-root>/scripts/init/run.sh --check` (exit 1 on drift) |
| Change tier or team | `bash <plugin-root>/scripts/init/run.sh --tier N --team solo|team` (or re-run `/ai-sdlc:sdlc-init`) |

## Uninstall

```
/plugin uninstall ai-sdlc@ai-sdlc-kit
```

Uninstalling removes the hooks, skills, agents, commands and the `sdlc-platform` command. It does not touch the repository. What stays, and how to remove it:

| Left behind | Remove with |
| --- | --- |
| Every rendered file listed in `.sdlc/managed-files.json` (paths and hashes): `REVIEW.md`, `docs/agents/*.md`, CI files, PR templates, `CODEOWNERS`, `branch-policies.json` | Read the manifest, delete the files whose hash still matches (unchanged since rendering), review the rest |
| The managed block in `CLAUDE.md` between `<!-- ai-sdlc:begin ... -->` and `<!-- ai-sdlc:end -->` | Delete the block; text outside it is yours |
| `CONTEXT.md` and `docs/adr/` | Rendered once, then owned by you and `mattpocock-skills:domain-modeling`; keep them |
| `.claude/settings.json` deny rules, `extraKnownMarketplaces`, `enabledPlugins` | Edit by hand; the deny rules on secrets are worth keeping |
| `.gitignore` lines for `.sdlc/ACTIVE_TICKET`, `.sdlc/FIX_MODE`, `.sdlc/UNLOCK_PROTECTED`, `.sdlc/release/`, `.sdlc/tmp/` | Delete the lines |
| `sdlc.config.json` and the `.sdlc/` tree (specs, tickets, verification reports, releases, postmortems, metrics) | Delete `sdlc.config.json` to make any remaining script exit silently; keep or archive `.sdlc/` as history |
| `scripts/sdlc-setup-wizard.sh` and `scripts/deploy.sh` | Yours; delete or keep |
| Branch protection or branch policies, registered pipelines, GitHub environments, the `ANTHROPIC_API_KEY` secret, the `sdlc-cost` label and issues | Platform settings; remove them in the platform UI or CLI |
| `mattpocock-skills` | `/plugin uninstall mattpocock-skills` if you no longer want the inner loop either |
