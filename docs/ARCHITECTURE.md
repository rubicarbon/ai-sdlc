# Architecture

## Purpose

`ai-sdlc` turns a repository into a workspace where an agent can run the whole delivery loop (grill, spec, tickets, build, review, verify, ship, learn) while a human keeps every irreversible decision. The plugin does not reimplement the inner development loop; that is `mattpocock-skills` from the official marketplace (see `docs/REUSE.md` for the skill-by-skill map). What `ai-sdlc` adds is the outer loop and the enforcement around it: a platform adapter contract that makes GitHub and Azure DevOps look identical, deterministic hooks that deny the shortcuts prose cannot prevent, read-only verifier and security-auditor subagents, CI templates with cost caps, DORA metrics with counterweights, and a bash eval harness that regression-tests the configuration itself. Skills advise; hooks and scripts decide.

## Plugin and repository: what lives where

The plugin is installed read-only into the Claude Code plugin cache. `/ai-sdlc:sdlc-init` (engine: `scripts/init/run.sh`) materialises a small set of files into the target repository. Nothing else is ever written into the repo by the plugin; every other artifact is produced by the loop itself under `.sdlc/`.

| Read-only in the plugin cache | Materialised into the target repo by `/ai-sdlc:sdlc-init` |
| --- | --- |
| `commands/` (`sdlc-init`, `sdlc-status`, `sdlc-upgrade`, `sdlc-start`, `sdlc-publish`, `sdlc-verify`) | `sdlc.config.json` (validated against the schema before it is written) |
| `skills/` (`sdlc-loop`, `sdlc-platform`, `sdlc-publish`, `sdlc-security-review`) | `CLAUDE.md` managed block (or `AGENTS.md` when only that exists), `CONTEXT.md` seed, `docs/agents/domain.md` |
| `agents/` (`sdlc-verifier`, `sdlc-security-auditor`, `sdlc-metrics-analyst`) | `.claude/settings.json` permission deny rules, merged, never clobbered |
| `hooks/hooks.json` and the seven hook scripts | `.gitignore` lines for the marker files |
| `scripts/` (init engine, config validator, adapters, publish, loop preconditions, ship gates, metrics, cost, reuse check) | Tier 1: `REVIEW.md`, `docs/agents/issue-tracker.md`, `.sdlc/` tree, `docs/adr/` |
| `bin/sdlc-platform` (on the Bash tool's `PATH` while the plugin is enabled) | Tier 3: CI workflows or pipelines, PR template, `CODEOWNERS` or `branch-policies.json` |
| `templates/` (`{{MARKER}}` sources for everything on the right) | `.sdlc/managed-files.json` (hash of every rendered file) |
| `config/sdlc.config.schema.json`, `evals/` | |

Two consequences follow from this split.

1. **Plugin hooks fire in every session, in every project.** Claude Code runs a plugin's hooks regardless of the repository. Every hook therefore sources `scripts/_root.sh`, then `scripts/_hook.sh`, which sources `scripts/_project.sh`. `_project.sh` walks up from the working directory to the git root looking for `sdlc.config.json` and, when none exists, exits 0 immediately with bash builtins only (no `jq`, no subshell). Silence outside an sdlc project is the contract; `evals/cases/hooks-silent.sh` proves it.
2. **`CLAUDE_PLUGIN_ROOT` is resolved by a shim, not trusted.** `hooks.json` passes `${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh` as an argument to `bash`, but Claude Code issues #42564 and #66557 document sessions where the variable was unset or unexpanded. `scripts/_root.sh` resolves the root in order: the variable (only when it points at a directory whose `.claude-plugin/plugin.json` names `ai-sdlc`), then the script's own location (`<root>/scripts/_root.sh`), then the newest `ai-sdlc` entry in the plugin cache. It never yields `/` or an empty string; on failure it prints a reinstall hint and returns 1, and the caller decides whether that blocks. `evals/cases/root-shim.sh` covers set, unset, empty, wrong and cache-fallback cases.

## The loop and its artifacts

`skills/sdlc-loop/SKILL.md` is the router: it names the next stage, the skill that runs it, and the artifact that must exist first. Preconditions are checked by `scripts/loop/precondition.sh <spec|tickets|build|verify|ship>` (exit 0: may start; exit 2: the missing artifact and the command that produces it), never from memory.

| # | Stage | Needs | Runs | Commits |
| --- | --- | --- | --- | --- |
| 1 | Frame | an idea | `/ai-sdlc:sdlc-start` (calls `mattpocock-skills:grilling` and `domain-modeling`) | `CONTEXT.md` terms, ADRs in `docs/adr/` |
| 2 | Spec | the framed conversation | human types `/mattpocock-skills:to-spec` | spec on the tracker or `.sdlc/features/<slug>/spec.md` |
| 3 | Tickets | spec | human types `/mattpocock-skills:to-tickets` | `issues/NN-*.md` with `Blocked by:` edges and `Status: ready-for-agent` |
| 4 | Publish | local spec and tickets; platform github or azure | `/ai-sdlc:sdlc-publish <feature-dir>` (`scripts/publish/publish.sh`) | tracker ids written back as first-line markers, `publish-manifest.json` |
| 5 | Build | `precondition.sh build` exit 0; one unblocked ticket | write `.sdlc/ACTIVE_TICKET`; human types `/mattpocock-skills:implement`; `tdd` at agreed seams | commits referencing the ticket id |
| 6 | Review | a diff since the branch point | `mattpocock-skills:code-review` | review notes on the PR or ticket |
| 7 | Verify | review done | `/ai-sdlc:sdlc-verify` spawns `sdlc-verifier` in a fresh context | `.sdlc/verify/<date>-<sha>.md` with a `**Verdict:**` line |
| 8 | Security | verify report | `sdlc-security-auditor` over the diff, ranked per `REVIEW.md` | findings on the PR |
| 9 | PR | verify PASS, findings addressed | `sdlc-platform pr_create`; a human code owner approves | the PR |
| 10 | Ship | approved PR, `pr_checks` pass | `/ai-sdlc:sdlc-ship` with `scripts/ship/preflight.sh --pr <id>` and a human running `scripts/ship/authorize.sh` | `.sdlc/releases/<version>.md`, `.sdlc/release/AUTHORIZED-<sha>` |
| 11 | Learn | a release or an incident | `/ai-sdlc:sdlc-postmortem`, `/ai-sdlc:sdlc-metrics-report` | `.sdlc/postmortems/*.md`, `.sdlc/metrics/*.json` |

Two kinds of skill matter for routing. Model-invocable skills (`grilling`, `domain-modeling`, `tdd`, `diagnosing-bugs`, `code-review`, `wizard`, `research`, `prototype`, `codebase-design`, `resolving-merge-conflicts`, `writing-for-agents`, and every `ai-sdlc:sdlc-*` skill) are called with the Skill tool. User-invoked skills (`to-spec`, `to-tickets`, `implement`, `wayfinder`, `grill-with-docs`, `grill-me`, `triage`, `handoff`, `setup-matt-pocock-skills`, `improve-codebase-architecture`, and every `/ai-sdlc:sdlc-*` command) have no description in the model's context, so when the route lands on one the skill stops and tells the human exactly what to type.

Artifacts live under `.sdlc/` (configurable as `artifacts.dir`):

```
.sdlc/
  features/<slug>/{spec.md, issues/NN-*.md, publish-manifest.json}
  verify/<date>-<sha>.md
  releases/<version>.md
  postmortems/*.md
  metrics/{baseline-*.json, raw-*.json, report-*.md, cost/}
  release/AUTHORIZED-<sha>        human-written, gitignored
  ACTIVE_TICKET  FIX_MODE  UNLOCK_PROTECTED   marker files, gitignored
  managed-files.json
```

ADRs stay in `docs/adr/` and the glossary in `CONTEXT.md`; both are owned by `mattpocock-skills:domain-modeling`, and `sdlc-init` never writes domain content into them.

## The adapter layer

`scripts/platform/contract.md` is the normative interface. Skills, commands, agents, CI templates and the Azure `docs/agents/issue-tracker.md` call only the contract, through the dispatcher `bin/sdlc-platform`, and never `gh`, `az` or `glab` directly.

**Contract summary.** Twelve functions: `platform_detect`, `work_item_create`, `work_item_get`, `work_item_link`, `work_item_comment`, `pr_create`, `pr_get`, `pr_comment`, `pr_checks`, `branch_protect_apply`, `ci_workflow_install`, `metrics_export`. Every function prints one JSON object on one line with identical field names and types on both platforms; a field a platform cannot supply is `null`, never omitted; ids are strings; bodies are always passed as files. Exit codes: 0 success, 1 failed (stderr starts with `ai-sdlc:`), 2 usage, 3 not supported on this platform (exact message form), 8 pending (`pr_checks` only). There are no silent no-ops.

**Dispatcher.** `bin/sdlc-platform [--platform github|azure] [--dry-run] [--mock] <function> [args]` resolves the platform in order `--platform`, `$SDLC_PLATFORM`, `platform` in `sdlc.config.json` (`both` and `auto` defer to detection), then `scripts/platform/_detect.sh` on the `origin` remote. `none` exits 3 for everything except `platform_detect`. It then executes `scripts/platform/<platform>/<function>.sh`. Every adapter script sources `_root.sh`, then `_common.sh` (which sources `_lib.sh` and `_project.sh`) and gets `out_json`, `md_to_html`, `require_gh`, `require_az`, `az_context` and `not_supported`.

**Mocks.** `scripts/platform/_mocks/bin/{gh,az}` are fake CLIs that answer the subset of commands the adapters use, keep counters and created items under `$SDLC_MOCK_STATE` so ids increment and repeated links are observable, and append every invocation to `$SDLC_MOCK_LOG`. `--mock` (or `SDLC_PLATFORM_MOCK=1`) prepends that directory to `PATH`. `--dry-run` (or `SDLC_DRY_RUN=1`) runs against the mocks with a temporary log and prints the CLI commands that would have run, one per line prefixed `+ `, without printing the JSON result.

**Conformance.** `scripts/platform/conformance.sh [--platform github|azure|all]` creates a scratch git repo per platform (remote plus `sdlc.config.json`), runs every function through the dispatcher under mocks, asserts exit codes and stdout shapes with `jq` predicates, checks idempotency of `work_item_link` and `branch_protect_apply`, checks the exact "not supported" message form, statically checks that no Azure script mentions `gh` and no GitHub script mentions `az`, then diffs the normalised key sets between platforms. It exits 1 on the first divergence. In this build the Azure adapter is mock-verified, not live-verified.

**Adding GitLab.** Create `scripts/platform/gitlab/` with the eleven per-function scripts (`work_item_create.sh` through `metrics_export.sh`; `platform_detect` is shared in `_detect.sh`), each sourcing `_root.sh` and `_common.sh` and printing the contract's shapes. Two one-line additions are also needed in the current code: the accepted-platform list in `bin/sdlc-platform` (`github|azure`) and the remote-URL pattern in `_detect.sh`. Then run `conformance.sh --platform all` until it passes. Skills, commands, agents and templates need no change.

## Tiers

`scripts/init/run.sh --tier N` renders cumulatively: tier 3 always includes tiers 0 to 2. Each tier requires the ones below it.

| Tier | Name | Files rendered or created | Behaviour switched on |
| --- | --- | --- | --- |
| 0 | Foundation | `sdlc.config.json`; `CLAUDE.md` managed block between `<!-- ai-sdlc:begin -->` and `<!-- ai-sdlc:end -->` (appended to an existing `CLAUDE.md` or `AGENTS.md`); `CONTEXT.md` (created once, then user-owned); `docs/agents/domain.md`; `.claude/settings.json` merged from `settings.json.tmpl`, `settings.<platform>.json.tmpl` and, for `--team team`, `settings.team.json.tmpl`; `.gitignore` lines for `ACTIVE_TICKET`, `FIX_MODE`, `UNLOCK_PROTECTED`, `release/`, `tmp/`; `.sdlc/managed-files.json` | Permission deny rules; every hook becomes active because `sdlc.config.json` now exists. `next_steps` tells the user to capture the metrics baseline now (`/ai-sdlc:sdlc-metrics-baseline`, `scripts/metrics/baseline.sh`), which refuses to run after Tier 1 without `--force` |
| 1 | Artifacts | `REVIEW.md`; `docs/agents/issue-tracker.md` from `issue-tracker-github.md.tmpl` or `issue-tracker-azure.md.tmpl`; `.sdlc/{features,verify,releases,postmortems,metrics/cost}/.gitkeep`; `docs/adr/.gitkeep` | Review policy with severity ranking, nit cap and human-only areas; the tracker doc that points upstream skills at `sdlc-platform` |
| 2 | Guardrails | No new files. `guardrails.requireTicket` is set to `true` in `sdlc.config.json` (and follows the tier on re-tier) | `guard-ticket-gate` denies source edits without `.sdlc/ACTIVE_TICKET`; `next_steps` says to run `sdlc-platform branch_protect_apply <default-branch>` |
| 3 | Automation | GitHub: `.github/workflows/sdlc-{pr-review,deploy,evals,cost-report}.yml`, `.github/PULL_REQUEST_TEMPLATE.md`, `.github/CODEOWNERS`. Azure: `.azuredevops/pipelines/sdlc-{pr-review,deploy,evals}.yml`, `.azuredevops/pull_request_template.md`, `.azuredevops/branch-policies.json`. `--platform both` renders both sets | Agent PR review inside CI with `cost.maxTurns`, `cost.maxBudgetUsd` and `cost.alertThresholdUsd` rendered in; human-gated production deploys; weekly evals; `next_steps` says to run `sdlc-platform ci_workflow_install`, create `scripts/deploy.sh`, and run the generated setup wizard for the `ANTHROPIC_API_KEY` secret and the production approval rule |

## Skills are advisory, hooks are deterministic

A skill can tell the agent not to edit tests; a hook makes the edit fail. All seven hooks are registered in `hooks/hooks.json` in exec form (`"command": "bash", "args": [...]`) with a 10 second timeout (90 for the post-edit hook), source `_root.sh` then `_hook.sh`, deny with exit 2 and a reason on stderr that names the fix, and exit 0 silently outside an sdlc project. Path lists are read from `sdlc.config.json` (`guardrails.*`) with built-in defaults, matched by the gitignore-style matcher in `scripts/_glob.sh`.

| Hook | Events | Rule enforced |
| --- | --- | --- |
| `guard-secrets` | PreToolUse on Read, Glob, Grep, Edit, Write, NotebookEdit, Bash, PowerShell | Denies access to `.env` and `.env.*` (except `.env.example`, `.env.sample`, `.env.template`, `.env.dist`), `secrets/**`, `*.pem`, `id_rsa*`, `id_ed25519*`, `*.p12`, `*.pfx`, `credentials.json`, `service-account*.json`, plus `~/.ssh`, `~/.aws`, `~/.azure`, `~/.config/gh`, `~/.kube/config`, `~/.netrc`, `~/.npmrc`, `~/.docker/config.json` and `guardrails.secretPaths`. For shell commands it extracts path-like tokens and also denies read-or-copy commands that mention `GITHUB_TOKEN=`, `GH_TOKEN=`, `AZURE_DEVOPS_EXT_PAT=`, `AWS_SHARED_CREDENTIALS_FILE`, `.netrc`, `id_rsa` or `id_ed25519` |
| `guard-protected-paths` | PreToolUse on Edit, Write, NotebookEdit, Bash, PowerShell | Denies modification (reads stay allowed) of `.github/workflows/**`, `.azuredevops/**`, `CODEOWNERS`, `sdlc.config.json`, `.claude/settings.json`, lockfiles (`package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `Cargo.lock`, `poetry.lock`, `go.sum`), `guardrails.protectedPaths`, and always `.sdlc/UNLOCK_PROTECTED` and `.sdlc/release/**`. A human unlocks one edit by creating `.sdlc/UNLOCK_PROTECTED`; the marker is itself protected so the agent cannot create it |
| `guard-verifier-readonly` | PreToolUse on Edit, Write, NotebookEdit, Bash, PowerShell | When `agent_type` is `sdlc-verifier` or `sdlc-security-auditor` (with or without a plugin prefix), denies every file edit and every write-shaped shell command (`hook_cmd_writes`: `rm`, `mv`, `cp`, `tee`, `sed -i`, `git add|commit|push|...`, package installs, PowerShell write cmdlets, and redirections other than to `/dev/null`) |
| `guard-test-edits` | PreToolUse on Edit, Write, NotebookEdit | While `.sdlc/FIX_MODE` exists, denies edits to test files (`*.test.*`, `*.spec.*`, `*_test.*`, `test_*.py`, `__tests__/`, `tests/`, `test/`, `*.feature`, `testdata/`, `fixtures/`, or `guardrails.testGlobs`), so a fix cannot pass by changing the test |
| `guard-ticket-gate` | PreToolUse on Edit, Write, NotebookEdit | When `guardrails.requireTicket` is true (default from tier 2), denies edits until `.sdlc/ACTIVE_TICKET` is non-empty. Always editable: `.sdlc/**`, `.scratch/**`, `docs/**`, `.claude/**`, `.agents/**`, `*.md`, `*.mdx`, `*.txt`, `.gitignore`, `.gitattributes`, and `guardrails.ticketFreePaths` |
| `gate-production` | PreToolUse on Bash, PowerShell | A command matching `environments.prod.deployCommandPatterns` (defaults include `git push * main|master|release/*|production`, `git push --tags*`, `gh workflow run *deploy*`, `gh release create *`, `az pipelines run|release *`, `az webapp|functionapp deploy*`, `kubectl apply|rollout *`, `helm upgrade|install *`, `terraform apply *`, `pulumi up *`, `serverless|sls deploy*`, `fly deploy*`, `vercel --prod*`, `netlify deploy --prod*`, `docker push *`) runs only when `.sdlc/release/AUTHORIZED-<HEAD sha>` exists and its `expires=` line is in the future |
| `post-edit-verify` | PostToolUse on Edit, Write | Runs `commands.format` (failures ignored) then `commands.lint` on the edited file when its extension is in `guardrails.verifyExtensions` (default `ts tsx js jsx mjs cjs py go rs cs java kt rb php sh bash`); a lint failure exits 2 with the first 25 lines so it is fixed now, not at review. Fails open on unparseable input |

`evals/cases/hooks-guards.sh` feeds each hook fixture stdin and asserts the deny; `hooks-silent.sh` asserts silence outside a project.

## The agent never merges

Four independent controls stand between an agent and production.

1. **Branch protection or policies.** `sdlc-platform branch_protect_apply <branch>` renders `templates/github/branch-protection.json` (required status checks from `github.requiredChecks`, code-owner reviews required, `review.requiredApprovals`, stale review dismissal, last-push approval, conversation resolution, no force pushes, admins included) or `templates/azure/branch-policies.json` (approver count, required reviewers from `azure.requiredReviewers` because Azure Repos has no CODEOWNERS, work-item linking, comment resolution, build policy on the `sdlc-pr-review` pipeline). The CI review comments only; the templates instruct it never to approve or request changes.
2. **Required human reviewers.** `.github/CODEOWNERS` defaults to the repository owner (`team.codeowners`, `@<owner>`); on Azure the same role is `azure.requiredReviewers`. `REVIEW.md` states that agent reviews are advisory and names the human-only areas.
3. **`scripts/ship/authorize.sh`.** Writes `.sdlc/release/AUTHORIZED-<sha>` with who, when and an expiry (`--ttl-minutes`, default 120). It refuses to run when `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT` or `CLAUDE_PROJECT_DIR` is set, so it cannot be run from inside a Claude Code tool call, and the target directory is denied to the agent by `guard-protected-paths`. Authorisation always comes from a person at their own terminal.
4. **`gate-production`.** The last deterministic stop: a deploy-shaped command without a fresh marker for HEAD is denied with the message to run `/ai-sdlc:sdlc-ship`. The deploy templates add a platform-side human gate as well: the GitHub `production` environment's required reviewers and the Azure `production` environment's Approvals check.

## The grader is never the author

`sdlc-verifier` runs the project's `commands.verify`, exercises each acceptance criterion with observable evidence (a test name, a command and its output line, or `file:line`), lists scope creep, and writes a report whose `PASS` requires every criterion `Pass` and exit 0; a single `Not verified` is `FAIL`. `sdlc-security-auditor` walks the `sdlc-security-review` check list per changed file and ranks per `REVIEW.md`. Both declare `tools: Read, Grep, Glob, Bash` and `model: inherit`. Plugin subagents cannot carry their own hooks or permission mode, so `guard-verifier-readonly` is what makes that allowlist read-only in practice: every edit and every write-shaped command from those agent types is denied. `/ai-sdlc:sdlc-verify` spawns the verifier in the foreground and stores the returned report verbatim under `.sdlc/verify/`, which `precondition.sh ship` later reads.

## Configuration

`sdlc.config.json` at the repo root is the single source of truth for every script and hook. Required keys: `version`, `platform`, `tier`, `commands`, `artifacts`. Sections: `repo`, `stack`, `commands` (`verify`, `format`, `lint`, `deployStaging`, `deployProduction`), `environments` (`dev`, `staging`, `prod` with `gate` and `deployCommandPatterns`), `team`, `review` (`requiredApprovals`, `nitCap`), `cost`, `guardrails` (`requireTicket`, `protectedPaths`, `secretPaths`, `testGlobs`, `ticketFreePaths`, `verifyExtensions`), `artifacts.dir`, `metrics` (`incidentLabel`, `deployEnvironment`, `maxPrs`), `github` (`requiredChecks`, `deployWorkflow`), `azure` (`organization`, `project`, `repo`, `workItemType`, `requiredReviewers`, `pipelineName`, `deployPipelineName`, `deployPipelineId`), `reuse.mattpocockSkills`, `pluginVersion`.

The schema is `plugins/ai-sdlc/config/sdlc.config.schema.json`; the root `sdlc.config.schema.json` is a byte copy so editors can follow the `$schema` URL. `scripts/config/validate.sh [config] [--schema file] [--quiet]` validates with `jq` alone (exit 0 valid, 1 invalid with one error per line, 2 usage). `run.sh` validates before writing and refuses to proceed on an invalid existing config.

`.sdlc/managed-files.json` records, per rendered path, the template name and the sha256 of what was written. On every re-run `run.sh` renders each template again and classifies the destination:

| Status | Meaning | Action without flags | With `--upgrade` | With `--force` |
| --- | --- | --- | --- | --- |
| `unchanged` | file equals the fresh render | nothing | nothing | nothing |
| `template-changed` | file equals what was recorded, but the plugin's template moved on | reported as pending; `--check` exits 1 | rewritten (`upgraded`) | rewritten |
| `user-edited` | file differs from both | kept and reported; never counted as drift | kept | rewritten (`overwritten`) |
| `missing` | recorded or expected file is absent | installed; under `--check` exits 1 | installed | installed |

`CONTEXT.md` is `create_once`: rendered on the first run and then user-owned (`kept`). `.claude/settings.json` goes through `scripts/init/merge-settings.sh` (objects merge, arrays union, existing scalars win). A clean re-run prints `"result":"already-initialised"` and writes nothing. `--dry-run` computes everything and writes nothing. The `sdlc-evals` CI template runs `run.sh --check` so drift fails the pipeline.

## Evals

`evals/run.sh [word...]` runs every bash case under `evals/cases/` (or those whose file name contains a word) with a fresh scratch directory in `$EVAL_TMP`. No LLM is involved: hooks are fed fixture stdin, adapters run against the bundled mocks, init runs non-interactively into scratch repos.

| Case | What it proves |
| --- | --- |
| `root-shim.sh` | `_root.sh` resolves the plugin root with the variable set, unset, empty, wrong, and via the cache fallback |
| `project-detect.sh` | `_project.sh` exits 0 silently outside an sdlc project, finds the config from a subdirectory, and honours `SDLC_PROJECT_OPTIONAL` |
| `glob-match.sh` | the gitignore-style matcher every hook uses for config glob lists |
| `hooks-silent.sh` | every hook exits 0 with no output, fast, in a non-sdlc repository |
| `hooks-guards.sh` | each guardrail fires in an sdlc project: secrets, protected paths, FIX_MODE, ticket gate, verifier read-only, production gate, post-edit lint |
| `config-validate.sh` | the jq validator accepts the example config and rejects common mistakes |
| `templates-render.sh` | every template renders from the example config with no marker left; examples carry no markers |
| `ci-templates.sh` | both CI sets render without markers; Azure never mentions `gh`, GitHub never mentions `az`; caps and gates are present |
| `init-dry-run.sh` | github and azure footprints, idempotent re-run, drift detection, user-edit protection, existing `CLAUDE.md` preserved, settings merged without clobbering |
| `adapters-conformance.sh` | both adapters behave identically under mocks (`conformance.sh`) |
| `publish-edges.sh` | a spec plus tickets publish to Azure DevOps and GitHub with blocking edges intact, ids written back, and a second run creates nothing |
| `loop-precondition.sh` | the build stage is gated on accepted, published tickets |
| `mattpocock-drift.sh` | `check-mattpocock.sh` detects a missing, renamed or re-typed upstream skill and an editable copy |
| `metrics-report.sh` | `report.py` turns the normalised export into Markdown with DORA keys and counterweights |
| `cost-report.sh` | `cost/report.sh` aggregates the three result formats and enforces the threshold |

Acceptance for a release of the kit: `claude plugin validate . --strict` passes, `evals/run.sh` passes, conformance is identical for both adapters under mocks, and `shellcheck -S warning` over `hooks/`, `scripts/`, the adapters and `bin/sdlc-platform` passes in the `sdlc-evals` CI job on ubuntu (run the same command locally when shellcheck is installed). Azure CLI behaviour is mock-verified in this build, not live-verified.

## Decisions and defaults

| Decision | Detail |
| --- | --- |
| Author and repository owner | The author name is `gergely.somogyvari` (plugin and marketplace manifests). GitHub does not allow dots in user names, so the repository owner is written `gergely-somogyvari` (`https://github.com/gergely-somogyvari/ai-sdlc-kit`), pending confirmation |
| Inner loop is reused, not rebuilt | `mattpocock-skills` supplies grill, spec, tickets, implement, tdd, review; `docs/REUSE.md` maps every skill; `scripts/reuse/check-mattpocock.sh` compares the installed plugin with the pinned manifest and `/ai-sdlc:sdlc-status` runs it |
| `bin/` provides `sdlc-platform` on `PATH` | Skills, agents and templates call the bare command; outside Claude Code use `<plugin-root>/bin/sdlc-platform` |
| `CLAUDE_PLUGIN_ROOT` shim | `scripts/_root.sh`: variable, then script path, then plugin cache; never `/` |
| Azure bridge | `/ai-sdlc:sdlc-init` writes `docs/agents/issue-tracker.md` pointing upstream skills at `sdlc-platform`, so `to-spec` and `to-tickets` publish to Azure Boards natively with `Successor` links for blocking edges; `/ai-sdlc:sdlc-publish` is the bulk push plus id write-back bridge |
| Runtime dependencies | bash, git, jq (the one hard dependency), plus `gh` or `az`; python3 only for `scripts/metrics/report.py` |
| jq CRLF wrapper | Windows jq emits CRLF, so `_lib.sh` defines `jq() { command jq -b "$@"; }` on msys, cygwin and win32 |
| Python detection by execution | `sdlc_python` runs `python3`, `python`, `py` in turn and keeps the first that reports major version 3, because the Windows Store stub exists on `PATH` but only prints an install hint |
| Exec-form hooks | `hooks.json` uses `"command": "bash"` with `args`, avoiding a shell parse of the command string on every tool call; `_root.sh` and `_project.sh` use builtins only on the silent path because a fork costs 30 to 150 ms on Windows |
| Release authorisation is human-only | `scripts/ship/authorize.sh` refuses inside a Claude session; the marker directory is protected; `gate-production` checks HEAD and expiry |
| Markdown on Azure | `scripts/platform/azure/_md2html.awk` converts the body to HTML for the description; the raw Markdown is kept verbatim as the first comment |
| PR size on Azure | `pr_get` prints `null` for `additions`, `deletions`, `changed_files`; `metrics_export` computes them with `git diff --shortstat` and first-commit time with `git log` when both commits exist locally |
| Templates | `{{MARKER}}` substitution only; `render.sh` flattens config keys (`repo.defaultBranch` to `REPO_DEFAULT_BRANCH`), exposes arrays as `NAME` and `NAME_JSON`, adds `PLUGIN_VERSION`, `PLUGIN_ID`, `MARKETPLACE_REPO`, `DATE`, `PROJECT_NAME`, and exits 1 listing any unresolved marker |
| Managed files | tracked by sha256 in `.sdlc/managed-files.json`; statuses `unchanged`, `template-changed`, `user-edited`, `missing`; user edits are never overwritten without `--force` |
| Eval harness | bash cases under `evals/cases`, no LLM |
| Dev-repo boundary | The kit's own repository is protected by `.claude/hooks/guard-repo-boundary.sh` plus deny rules in `.claude/settings.json` (see `.dev/README.md`); the gitignored kill switch `.dev/BOUNDARY_HOOK_DISABLED` disables the hook with a warning, only to prove the deny rules block independently |
| CODEOWNERS | defaults to the repository owner; Azure Repos has no CODEOWNERS, so required reviewers come from `azure.requiredReviewers` |
| Metrics baseline first | `baseline.sh` refuses after Tier 1 unless `--force`, and records the late baseline as such |
| `metrics_export` normalised schema | one file shape on both platforms: `platform`, `repo`, `since`, `until`, `exported_at`, `prs[]` (`id`, `created_at`, `merged_at`, `first_review_at`, `additions`, `deletions`, `changed_files`, `first_commit_at`, `author`, `is_revert`), `deployments[]` (`id`, `environment`, `started_at`, `finished_at`, `status`, `sha`), `incidents[]` (`id`, `opened_at`, `closed_at`, `labels`), `reverts[]` (`sha`, `committed_at`, `reverts_sha`); dates ISO 8601 UTC; `report.py` consumes it unchanged |
| Cost caps | `cost.maxTurns` (default 40), `cost.maxBudgetUsd` (default 5), `cost.alertThresholdUsd` (default 25) are rendered into the PR review templates as `--max-turns` and `--max-budget-usd`; each run writes `sdlc-cost.json` and fails when spend exceeds the ceiling; `sdlc-cost-report.yml` sums a week and opens an issue labelled `sdlc-cost` above the threshold |
| Deploy mechanics belong to the repo | the deploy templates call `scripts/deploy.sh <environment> <sha>`, which the repository provides |
