# Reuse map: `mattpocock-skills` and where `ai-sdlc` picks up

`ai-sdlc` deliberately does not reimplement the inner development loop. That loop already exists as the `mattpocock-skills` plugin in Claude Code's official marketplace (MIT). This document records exactly what was read, what each of their skills covers, what it leaves uncovered, and the seam where this plugin takes over.

## What was read, and how

| Item | Value |
| --- | --- |
| Source | `https://github.com/mattpocock/skills`, branch `main` |
| Commit | `6654f6b60cd9d5be8b54c6fafe44346dabeb3b76` (committed 2026-08-24T14:19:57Z) |
| Plugin version in `.claude-plugin/plugin.json` | `1.2.3` |
| Marketplace name / plugin name | `mattpocock` / `mattpocock-skills` |
| Skill namespace as installed | `mattpocock-skills:<skill>` (namespacing uses the plugin name, not the marketplace name) |
| How it was read | Raw `SKILL.md` files and manifests fetched over the network. The installed copy in `~/.claude/plugins/cache/` was not read (out of bounds for the build session), so the source and the installed artifact can drift. `scripts/reuse/check-mattpocock.sh` compares the installed plugin against `scripts/reuse/mattpocock-manifest.json`, which pins the list below. |

The plugin ships 25 skills, listed explicitly in `plugin.json` (`engineering/` and `productivity/` buckets). `misc/`, `in-progress/`, `deprecated/` and `personal/` are not shipped.

## Two facts that shape the integration

1. **User-invoked skills cannot be reached by other skills or by the model.** Every skill with `disable-model-invocation: true` has no description in the model's context, so only a human typing `/mattpocock-skills:<name>` can run it. `ai-sdlc` skills therefore *hand off* to those by telling the human what to type; they can only *call* the model-invocable ones via the Skill tool.
2. **The issue tracker is configured in prose.** `/setup-matt-pocock-skills` writes `docs/agents/issue-tracker.md` (choices: GitHub via `gh`, GitLab via `glab`, local markdown under `.scratch/`, or "Other" as a freeform description). `to-spec`, `to-tickets`, `wayfinder`, `code-review` and `triage` read that file to learn how to publish, fetch and link tickets. Azure DevOps is not offered. `ai-sdlc` supplies an Azure `issue-tracker.md` that routes every operation through the `sdlc-platform` adapter contract, so their skills publish to Azure Boards natively, with real blocking links. The README's mention of Linear is stale; the skill offers GitHub, GitLab, local or Other.

## Stage map

Invocation: **U** = user-invoked only (`disable-model-invocation: true`); **M** = model-invocable (callable from our skills via the Skill tool).

| Stage | Their skill | Inv. | What it does | What it leaves uncovered | Where `ai-sdlc` picks up |
| --- | --- | --- | --- | --- | --- |
| Intent | `grill-me` | U | Relentless interview for non-code plans (`grilling` under the hood) | Nothing platform-related | `sdlc-loop` names it as the entry for non-code work |
| Intent | `grill-with-docs` | U | Calls `grilling` + `domain-modeling`: interview that updates `CONTEXT.md` and offers ADRs inline | Recording the *outcome* as a gated artifact | `sdlc-start` performs the same two calls itself (both are M), then hands off to `/mattpocock-skills:to-spec` |
| Intent | `grilling` | M | The interview discipline | | Called by `sdlc-start`; referenced by `sdlc-postmortem` for the "why" interview |
| Spec | `to-spec` | U | Synthesises the conversation into a spec (Problem, Solution, User Stories, Implementation/Testing Decisions, Out of Scope) and publishes it to the configured tracker with the `ready-for-agent` label | Azure DevOps; write-back of tracker IDs into local artifacts; storing the spec in the repo | Azure `issue-tracker.md` makes "publish" mean `sdlc-platform work_item_create`; `sdlc-publish` pushes an existing local spec and records IDs; the spec text is stored under `.sdlc/specs/` by `sdlc-publish` |
| Plan | `to-tickets` | U | Tracer-bullet vertical slices, each with **blocking edges**; publishes one issue per ticket in dependency order; native blocking on real trackers, `Blocked by:` lines locally | Azure DevOps `Successor`/`Predecessor` links; bulk re-publish; ID write-back | `sdlc-platform work_item_link --type blocks`; `sdlc-publish` applies edges in a second pass and writes IDs back |
| Plan (large) | `wayfinder` | U | Map of decision tickets on the tracker, resolved one per session; relies on the tracker doc's "Wayfinding operations" section | Azure wayfinding operations | The Azure `issue-tracker.md` template carries a full "Wayfinding operations" section expressed in `sdlc-platform` calls |
| Build | `implement` | U | Builds from spec or tickets, drives `/tdd` at pre-agreed seams, closes with `/code-review`, commits to the current branch | Guardrails: nothing prevents reading secrets or deploying | `guard-secrets.sh`, `gate-production.sh` (configured patterns); `sdlc-loop` requires accepted tickets before this stage and asks for `commands.format`, `commands.lint` and `commands.verify` before the work is called done |
| Test | `tdd` | M | Red → green loop, seams agreed up front, anti-patterns | A reviewer who reads test diffs | `sdlc-loop` and `REVIEW.md`: the regression test is committed red first and changed only in its own commit |
| Test | `diagnosing-bugs` | M | Gated loop: build a red feedback loop, reproduce, minimise, hypothesise, instrument, fix, regression test, clean up | Keeping the fix and the test change apart for review | `sdlc-loop` bug-fix protocol: commit the regression test red, fix without touching it, separate commit if the test was wrong |
| Review | `code-review` | M | Two-axis review (repo standards incl. a Fowler smell baseline; spec compliance) as parallel subagents; reads the spec via the tracker doc | Running the software; security review; ranking with a nit cap; a human gate | `sdlc-verifier` runs the verification command and acceptance criteria *after* `code-review`; `sdlc-security-auditor` + `REVIEW.md`; branch protection requires a human code-owner approval |
| Design | `codebase-design` | M | Deep-module vocabulary (module, interface, depth, seam, adapter, leverage, locality) | | Referenced from `sdlc-loop`; the adapter layer here follows its adapter/seam vocabulary |
| Design | `improve-codebase-architecture` | U | Architecture survey with an HTML report | | Named in `sdlc-loop` for the "learn" stage |
| Design | `domain-modeling` | M | Owns `CONTEXT.md` (glossary only) and `docs/adr/NNNN-slug.md` (1-3 sentence ADRs) | | `CONTEXT.md.tmpl` is an empty seed in their format; `artifacts/adr.md.tmpl` follows `ADR-FORMAT.md`; `sdlc-init` never writes domain content |
| Support | `handoff` | U | Compacts the conversation into a handoff doc in the OS temp dir | | Named in `sdlc-loop`; `sdlc-ship` suggests it before a release branch is handed over |
| Support | `research` | M | Background agent researches against primary sources and writes a cited Markdown file | | Used by `sdlc-postmortem` for external-cause research |
| Support | `resolving-merge-conflicts` | M | Resolves an in-progress merge/rebase conflict | | Named in `sdlc-loop` |
| Support | `triage` | U | Issue/PR state machine with five canonical labels; reads the tracker doc | Azure label vocabulary | Azure `issue-tracker.md` maps the five roles to `System.Tags` |
| Support | `wizard` | M | Generates a bash wizard for steps only a human can perform (URLs, secret capture, `.env` and `gh secret` writes) | Azure DevOps variable groups / service connections | Not called by `ai-sdlc`. The manual platform steps (secrets, environments, approvals, variable groups, policies) are documented in `docs/PLATFORM-SETUP.md`; a team may use `wizard` to turn that page into its own interactive script |
| Support | `writing-for-agents` | M | Rules for documents agents consume: pointers, information hierarchy, leading words, positive phrasing, pruning; `SKILL-MECHANICS.md` on invocation and router skills | | Every `ai-sdlc` skill, command and template was written against it; `sdlc-loop` is a router skill in its sense |
| Support | `prototype` | M | Throwaway prototype to answer a design question | | Named in `sdlc-loop` |
| Setup | `setup-matt-pocock-skills` | U | Writes `docs/agents/{issue-tracker,domain,triage-labels}.md` and an `## Agent skills` block in `CLAUDE.md`/`AGENTS.md` | Azure DevOps; detection of a duplicate editable copy | `sdlc-init` writes the Azure `issue-tracker.md` itself and tells the user to answer "Other" (or skip) if they run their setup later; detects `npx skills add` copies under `.claude/skills/` and `.agents/skills/` and warns |
| Other | `ask-matt`, `teach`, `to-questionnaire`, `wait-what` | U | Personal/teaching skills | | Not part of the SDLC loop; not referenced |

## What they do *not* ship (checked against the repository tree)

| Capability | Present upstream? | Evidence |
| --- | --- | --- |
| `hooks/hooks.json` or any plugin hook | No | No `hooks/` directory; `plugin.json` declares only `skills` |
| Permission rules / `settings.json` | No | Not present |
| CI workflows or pipelines for the target repo | No | `.github/` in their repo is for their own repo only |
| Metrics, DORA, baseline capture | No | No scripts beyond `scripts/{link-skills,list-skills}.sh` and a version sync |
| Security review of diffs | No | `code-review` covers standards and spec only |
| Azure DevOps | No | Trackers: GitHub, GitLab, local, Other |
| Evals of the configuration | No | Not present |
| Cost caps or spend reporting | No | Not present |
| Production gate / release loop / postmortem | No | Not present |

Near misses, and why they change nothing on our list:

- `skills/misc/git-guardrails-claude-code` (not shipped in the plugin) is a `PreToolUse` hook script that blocks `git push`, `git reset --hard`, `git clean -f`, `git branch -D`, `git checkout .` with exit 2. It is prior art for our hook style; `gate-production.sh` covers the `git push` to protected branches case with release authorisation rather than a blanket block.
- `skills/in-progress/retro` (not shipped) is a retrospective on the *agent environment* (navigation pointers, automated checks, no-ops), not an incident postmortem. `sdlc-postmortem` is about production incidents and defect escape; it cites `retro` as a companion for environment learnings.
- `skills/misc/setup-pre-commit` (not shipped) installs husky + lint-staged. `sdlc-loop` asks the agent to run `commands.format` and `commands.lint` after a coherent change instead; the plugin does not run them per edit and does not touch the repo's commit hooks.

**Cut list: nothing.** Every item on the "build these" list is genuinely uncovered upstream.

## Naming: no shadowing

Their skill names: `ask-matt`, `code-review`, `codebase-design`, `diagnosing-bugs`, `domain-modeling`, `grill-me`, `grill-with-docs`, `grilling`, `handoff`, `implement`, `improve-codebase-architecture`, `prototype`, `research`, `resolving-merge-conflicts`, `setup-matt-pocock-skills`, `tdd`, `teach`, `to-questionnaire`, `to-spec`, `to-tickets`, `triage`, `wait-what`, `wayfinder`, `wizard`, `writing-for-agents`.

Ours all carry the `sdlc-` prefix (`sdlc-init`, `sdlc-status`, `sdlc-upgrade`, `sdlc-start`, `sdlc-publish`, `sdlc-verify`, `sdlc-ship`, `sdlc-postmortem`, `sdlc-metrics-baseline`, `sdlc-metrics-report`, `sdlc-loop`, `sdlc-platform`, `sdlc-metrics`, `sdlc-security-review`, and agents `sdlc-verifier`, `sdlc-security-auditor`, `sdlc-metrics-analyst`). No name is shared and none is a confusable variant (`sdlc-verify` runs software; their `code-review` reads diffs).

## Keeping this map honest

`scripts/reuse/mattpocock-manifest.json` pins the skill list, invocation type and version above. `scripts/reuse/check-mattpocock.sh` reads the installed plugin (`plugin.json` version and the skill directories it lists) and reports added, removed or re-typed skills, so `sdlc-loop` can say when its routing table is stale. `/sdlc-status` runs it.
