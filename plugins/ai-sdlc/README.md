# ai-sdlc

Claude Code plugin that turns a software project into an AI-native SDLC workspace. It supplies the outer loop (a GitHub and Azure DevOps adapter behind one contract, deterministic hooks, read-only verifier and security-auditor subagents, CI review with cost caps, DORA metrics, evals) around the inner loop provided by the `mattpocock-skills` plugin (grill, spec, tickets, implement, tdd, code review).

## Install

```
/plugin marketplace add rubicarbon/ai-sdlc
/plugin install ai-sdlc@ai-sdlc-kit
/plugin install mattpocock-skills
/ai-sdlc:sdlc-init
```

## Components

### Commands (`/ai-sdlc:<name>`, user-invoked)

| Command | Does |
| --- | --- |
| `sdlc-init` | Detects the repo, asks platform, tier, team mode and commands, writes `sdlc.config.json` and renders the tier's files |
| `sdlc-status` | Reports whether the repo is an sdlc project, its tier, config validity and the next stage |
| `sdlc-upgrade` | Re-renders files whose template changed after a plugin update; never overwrites user-edited files without `--force` |
| `sdlc-start` | Frames a change with `grilling` and `domain-modeling`, then hands off to `/mattpocock-skills:to-spec` |
| `sdlc-publish` | Pushes a local spec and tickets to the tracker with blocking edges and writes the ids back |
| `sdlc-verify` | Runs the `sdlc-verifier` subagent (optionally the security auditor) and stores the report under `.sdlc/verify/` |
| `sdlc-ship` | Release preflight, release notes, rollback rehearsal; waits for a human's `authorize.sh` |
| `sdlc-postmortem` | Writes an incident or defect-escape postmortem under `.sdlc/postmortems/` |
| `sdlc-metrics-baseline` | Captures the pre-adoption metrics baseline (refused after tier 1 unless forced) |
| `sdlc-metrics-report` | Exports the period, renders the DORA report and runs the metrics analyst |

### Skills (`ai-sdlc:<name>`, model-invocable)

| Skill | Does |
| --- | --- |
| `sdlc-loop` | Router: names the next stage, the skill to run and the artifact that must exist first |
| `sdlc-platform` | How to call `sdlc-platform` for every GitHub or Azure DevOps operation |
| `sdlc-publish` | Procedure around `scripts/publish/publish.sh` |
| `sdlc-ship` | The release gates and the human authorisation step |
| `sdlc-postmortem` | Postmortem interview and template |
| `sdlc-metrics` | How metrics are exported, reported and read honestly |
| `sdlc-security-review` | Check list and report format for a security review of a diff |

### Agents

| Agent | Does |
| --- | --- |
| `sdlc-verifier` | Fresh-context verifier: runs the verify command and the acceptance criteria, reports with evidence; read-only by hook |
| `sdlc-security-auditor` | Ranks security findings in a diff per `REVIEW.md`; read-only by hook |
| `sdlc-metrics-analyst` | Turns metrics files into a short narrative with sample sizes |

### Hooks (`hooks/hooks.json`)

| Hook | Event | Does |
| --- | --- | --- |
| `guard-secrets` | PreToolUse | Denies access to secret files and credential directories |
| `guard-protected-paths` | PreToolUse | Denies edits to protected paths unless `.sdlc/UNLOCK_PROTECTED` exists |
| `guard-verifier-readonly` | PreToolUse | Denies edits and write-shaped commands from the verifier and auditor agents |
| `guard-test-edits` | PreToolUse | Denies test edits while `.sdlc/FIX_MODE` exists |
| `guard-ticket-gate` | PreToolUse | Denies source edits without `.sdlc/ACTIVE_TICKET` when `guardrails.requireTicket` is on |
| `gate-production` | PreToolUse | Denies production commands without a fresh `.sdlc/release/AUTHORIZED-<sha>` |
| `post-edit-verify` | PostToolUse | Runs the configured formatter and linter on the edited file |

Every hook exits 0 silently in a repository without `sdlc.config.json`.

### Also shipped

`bin/sdlc-platform` (adapter dispatcher; contract in `scripts/platform/contract.md`), `scripts/` (init engine, config validation, publish, loop preconditions, ship preflight and human authorisation, metrics, cost report, upstream drift check), `templates/` (rendered by init), `evals/` (bash regression cases), `config/sdlc.config.schema.json`.

## Requirements

Claude Code 2.1.224 or newer, bash, git, jq; `gh` for GitHub or `az` with the `azure-devops` extension for Azure DevOps; python3 for metrics reports only.

## Documentation

The repository root `README.md` has the quickstart; `docs/` holds `ARCHITECTURE.md`, `REUSE.md`, `ADOPTION.md`, `METRICS.md` and `SECURITY.md`.
