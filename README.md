# ai-sdlc-kit

`ai-sdlc` is a Claude Code plugin that adds the outer loop of software delivery around the inner loop that the `mattpocock-skills` plugin already provides. Their skills take an idea through grilling, spec, tickets, implementation and code review. This plugin adds what a team needs around that: a platform adapter that makes GitHub and Azure DevOps first-class and interchangeable, two targeted deterministic hooks (secret material; production commands the project configured, without a human's authorisation) plus a read-only verifier and security auditor, CI review with cost caps, DORA metrics with counterweights, and evals for the configuration itself. It is project-agnostic (any stack; the only per-project input is the verify command) and platform-agnostic (every platform call goes through one contract).

## Quickstart

### Prerequisites

| Tool | Why | Check |
| --- | --- | --- |
| Claude Code 2.1.224 or newer | plugin hooks with `args`, `${CLAUDE_PLUGIN_ROOT}` | `claude --version` |
| git | every script runs at a repository root | `git --version` |
| jq | the one hard runtime dependency of hooks, adapters and init | `jq --version` |
| `gh` (GitHub) or `az` with the `azure-devops` extension (Azure DevOps) | the adapter drives the platform CLI; skip both for `--platform none` | `gh auth status` or `az account show` |
| python3 | metrics reports only (`scripts/metrics/report.py`, standard library) | `python3 --version` |

Bash is required as well; on Windows the Git for Windows bash is enough.

### Install

Inside a Claude Code session, in any directory:

```
/plugin marketplace add rubicarbon/ai-sdlc
/plugin install ai-sdlc@ai-sdlc-kit
/plugin install mattpocock-skills
```

`mattpocock-skills` comes from Claude Code's official marketplace and supplies the inner loop; `docs/REUSE.md` maps every one of its skills to the place where this plugin picks up. Restart the session (or run `/reload-plugins`), open the repository you want to set up, and run:

```
/ai-sdlc:sdlc-init
```

### What `/ai-sdlc:sdlc-init` asks and writes

The command runs `scripts/init/detect.sh` first (platform from the git remote, CLI presence and login, stack and verify-command candidates, whether `mattpocock-skills` is installed) and only asks what detection could not settle:

| Question | Config key | Notes |
| --- | --- | --- |
| Platform | `platform` | `github`, `azure`, `both` or `none`; Azure also needs organisation URL, project and repository |
| Tier | `tier` | 0 to 3, see the tiers table below; rendering is cumulative |
| Team mode | `team.mode` | `solo` or `team` (team adds the shared settings fragment) |
| Verify, format, lint commands | `commands.verify`, `commands.format`, `commands.lint` | verify is the one command that proves the code works; format and lint are run by the agent after a coherent change, not per edit |
| Environments | `environments` | default `dev,staging,prod`; `environments.prod.deployCommandPatterns` starts as `git push * <default branch>` and is the only source of production patterns for the gate |
| Cost caps (tier 3) | `cost.maxTurns`, `cost.maxBudgetUsd`, `cost.alertThresholdUsd` | rendered into the CI review workflow |

The answers become `sdlc.config.json`, validated against `sdlc.config.schema.json` with jq alone. Everything rendered is recorded by hash in `.sdlc/managed-files.json`, so a later `/ai-sdlc:sdlc-upgrade` can tell an unchanged file from one whose template changed from one you edited; user-edited files are never overwritten without `--force`. Re-running init on a finished project reports `already-initialised`. Templates use `{{MARKER}}` substitution only and `render.sh` refuses to write a file with an unresolved marker.

### The loop

| Stage | You run | Artifact committed |
| --- | --- | --- |
| Frame | `/ai-sdlc:sdlc-start <one line>` (calls `mattpocock-skills:grilling` and `domain-modeling`) | terms in `CONTEXT.md`, ADRs in `docs/adr/` |
| Spec | `/mattpocock-skills:to-spec` | `spec.md` (locally or on the tracker) |
| Tickets | `/mattpocock-skills:to-tickets` | `issues/NN-*.md` with `Blocked by:` edges |
| Publish | `/ai-sdlc:sdlc-publish <feature-dir>` | tracker ids written back, `publish-manifest.json` |
| Build | `/mattpocock-skills:implement` on a branch named for the ticket (drives `tdd`); run `commands.format`, `commands.lint` and `commands.verify` before finishing | commits referencing the ticket |
| Review | `mattpocock-skills:code-review` (the agent calls it) | review notes |
| Verify | `/ai-sdlc:sdlc-verify [--security]` | `.sdlc/verify/<date>-<sha>.md` with a Verdict line |
| PR | `sdlc-platform pr_create ...`; a human code owner approves | the pull request |
| Ship | `/ai-sdlc:sdlc-ship` plus `authorize.sh` run by a human at their own terminal | `.sdlc/releases/<version>.md`, `.sdlc/release/AUTHORIZED-<sha>` |
| Learn | `/ai-sdlc:sdlc-postmortem`, `/ai-sdlc:sdlc-metrics-report` | `.sdlc/postmortems/*.md`, `.sdlc/metrics/*` |

Ask `ai-sdlc:sdlc-loop` (or `/ai-sdlc:sdlc-status`) what comes next; it checks artifacts with `scripts/loop/precondition.sh`, not memory. Skills marked user-invoked upstream (`to-spec`, `to-tickets`, `implement`, `wayfinder`, `grill-with-docs`, `grill-me`, `triage`, `handoff`) can only be typed by a human, so this plugin's skills hand off to them by telling you what to type.

### Tiers

| Tier | Name | What init renders |
| --- | --- | --- |
| 0 | Foundation | managed block in `CLAUDE.md`, `CONTEXT.md` seed, `docs/agents/domain.md`, deny rules in `.claude/settings.json`, `.gitignore` markers; the last next step is the metrics baseline |
| 1 | Artifacts | `REVIEW.md`, `docs/agents/issue-tracker.md` (GitHub or Azure), the `.sdlc/` tree, `docs/adr/` |
| 2 | Review policy | branch protection through `sdlc-platform branch_protect_apply`; tiers never turn on extra hooks |
| 3 | Automation | CI templates (`.github/workflows/sdlc-*.yml` or `.azuredevops/pipelines/sdlc-*.yml`), PR template, `CODEOWNERS` (GitHub; Azure uses `azure.requiredReviewers`), cost caps, `sdlc-platform ci_workflow_install`; the deploy workflow runs `commands.deployStaging` and `commands.deployProduction` (required, or `--no-deploy`); human-only platform steps are in `docs/PLATFORM-SETUP.md` |

Tier 3 always includes tiers 0 to 2. The metrics baseline is captured at tier 0 because `scripts/metrics/baseline.sh` refuses to run once tier 1 artifacts exist (a baseline taken after the change is not a baseline; `--force` overrides and records that fact).

### Platform adapter

`bin/sdlc-platform` is on the PATH while the plugin is enabled and dispatches to `scripts/platform/github/*.sh` or `scripts/platform/azure/*.sh`, one script per function of the contract in `scripts/platform/contract.md` (work items, links, comments, pull requests, checks, branch protection, CI install, metrics export), each printing one JSON object with identical field names on both platforms. Skills, agents, CI templates and the Azure `docs/agents/issue-tracker.md` call only this command, never `gh` or `az`, which is how `to-spec` and `to-tickets` publish to Azure Boards natively (blocking edges become `Successor` links; Markdown bodies are converted to HTML and the raw Markdown is kept as the first comment). `scripts/platform/conformance.sh` runs the same assertions against both adapters under the bundled CLI mocks and fails on the first divergence.

### Guardrails

Routine development is not gated: source, tests, lockfiles, CI files, `sdlc.config.json`, `.claude/settings.json`, installs, scripts and staging deploys all run without marker files. Four hooks live in `plugins/ai-sdlc/hooks/`; all exit 0 silently in any repository without `sdlc.config.json`.

- `guard-secrets`: denies reads and writes of `.env` and `.env.*` (except `.env.example`, `.env.sample`, `.env.template`, `.env.dist`), `secrets/**`, private keys by name (`*-key.pem`, `*.key.pem`, `privkey.pem`, `*.key`, `id_rsa`, `id_ed25519`, `id_ecdsa`, `*.p12`, `*.pfx`), `credentials.json`, `service-account*.json`, and the SSH, AWS, Azure and gh credential directories in the home directory, including through Bash and PowerShell. Public certificates (`cert.pem`, `fullchain.pem`, `*.crt`) and `*.pub` keys are readable. `guardrails.secretPaths` replaces the project defaults (an explicit `[]` turns them off; the home-directory list stays); the deny rules written to `.claude/settings.json` are a second layer with the same names and are edited separately (see `docs/SECURITY.md`).
- `guard-protected-paths`: denies edits to `guardrails.protectedPaths` (nothing unless the project configures some) and always to the release-authorisation markers `.sdlc/release/**` and `.sdlc/UNLOCK_PROTECTED`. A human unlocks a configured path for one edit by creating `.sdlc/UNLOCK_PROTECTED`; the markers themselves never unlock.
- `guard-verifier-readonly`: the `sdlc-verifier` and `sdlc-security-auditor` subagents cannot edit files. Their shell is not restricted; their prompts tell them to run and report, never fix, and a verification `PASS` must say which tree it verified (`Tree: clean` or `Tree: isolated` via `scripts/verify/run-isolated.sh`).
- `gate-production`: commands matching `environments.prod.deployCommandPatterns` (no built-in patterns; init seeds `git push * <default branch>` and the configured production deploy command) run only while `.sdlc/release/AUTHORIZED-<HEAD sha>` is a complete, unexpired marker bound to `HEAD` (every field exactly once, validated by `scripts/ship/_authz.sh`) written by `scripts/ship/authorize.sh`, which refuses to run inside a Claude session.

Formatting, linting and verification are the agent's job after a coherent change (`commands.format`, `commands.lint`, `commands.verify`), not a per-edit hook. Ticket discipline and test-change review are workflow rules held by `REVIEW.md` and the reviewer, not by hooks.

### Metrics

`scripts/metrics/baseline.sh` and `collect.sh` export pull requests, deployments, incidents and reverts through `sdlc-platform metrics_export`, and `scripts/metrics/report.py` renders the four DORA keys plus counterweights (revert rate, PR size, review latency, code churn, defect escape rate, cost per merged PR from `scripts/cost/report.sh`) with the sample size next to every number. The `sdlc-metrics-analyst` agent turns that into a short narrative for `/ai-sdlc:sdlc-metrics-report`; on Azure, PR size is null unless computed from local git.

## Repository layout

```
.claude-plugin/marketplace.json     marketplace "ai-sdlc-kit" (one plugin)
sdlc.config.schema.json             byte copy of the plugin schema, for editors
docs/                               ARCHITECTURE, REUSE, ADOPTION, METRICS, SECURITY
plugins/ai-sdlc/
  .claude-plugin/plugin.json        name ai-sdlc, version 0.1.0
  commands/                         /ai-sdlc:sdlc-* slash commands
  skills/                           model-invocable skills (sdlc-loop is the router)
  agents/                           sdlc-verifier, sdlc-security-auditor, sdlc-metrics-analyst
  hooks/                            hooks.json plus the four hook scripts
  bin/sdlc-platform                 adapter dispatcher
  scripts/                          init, config, publish, loop, ship, metrics, cost, reuse, platform/{github,azure,_mocks}
  templates/                        {{MARKER}} templates rendered by init
  evals/                            bash regression cases, no LLM
  config/sdlc.config.schema.json    the schema
.dev/                               build-session controls (VERIFY.md, scratch)
```

## Development

```bash
bash plugins/ai-sdlc/evals/run.sh                       # every eval case; add a word to filter
bash plugins/ai-sdlc/scripts/platform/conformance.sh    # both adapters under mocks, diffed
python -B -m unittest discover -s plugins/ai-sdlc/evals/python   # report.py unit tests
claude plugin validate . --strict                       # marketplace and plugin manifests
```

`.github/workflows/ci.yml` runs the same checks plus shellcheck, a YAML parse of every rendered CI template and actionlint on every push and pull request.

Evals are plain bash cases under `plugins/ai-sdlc/evals/cases/`: hooks are fed fixture stdin, adapters run against the mock `gh` and `az` in `scripts/platform/_mocks/bin`, and init runs non-interactively into scratch repos under `.dev/scratch/`. Azure CLI behaviour is therefore mock-verified, not live-verified, in this build; `.dev/VERIFY.md` lists what still needs a real project and how to check it. `shellcheck -S warning` runs in the `sdlc-evals` CI template on ubuntu; run it locally when it is installed.

## Uninstall

```
/plugin uninstall ai-sdlc@ai-sdlc-kit
/plugin marketplace remove ai-sdlc-kit
```

Files rendered into your project stay; `.sdlc/managed-files.json` lists them if you want to remove them.

## Documentation

- `docs/ARCHITECTURE.md`: components, data flow, the adapter contract and the hook model
- `docs/REUSE.md`: what `mattpocock-skills` covers and where this plugin picks up
- `docs/ADOPTION.md`: tier by tier rollout for a team
- `docs/METRICS.md`: what is measured, how, and what the counterweights guard against
- `docs/SECURITY.md`: threat model, secrets, the production gate and the human-only steps
- `docs/PLATFORM-SETUP.md`: the exact manual steps on GitHub and Azure DevOps (secrets, environments, approvals, variable groups, policies)
- `plugins/ai-sdlc/scripts/platform/contract.md`: the normative adapter interface

License: MIT (see `LICENSE`).
