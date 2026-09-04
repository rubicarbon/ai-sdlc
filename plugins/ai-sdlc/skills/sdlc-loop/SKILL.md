---
name: sdlc-loop
description: "Route the next SDLC stage. Use when starting or resuming feature work, when asked what comes next, before implementing, reviewing, verifying or shipping a change, when fixing a bug under test, or after an incident. Names the skill to run (ai-sdlc or mattpocock-skills) and the artifact that must exist first."
---

# SDLC loop

The loop is grill → spec → tickets → build → review → verify → ship → learn. Every stage ends by committing an artifact that the next stage reads. Nothing is implemented without an accepted ticket; nothing merges without a human at the gate.

**Check preconditions with the script, never from memory:**

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/loop/precondition.sh" <spec|tickets|build|verify|ship>
```

Exit 0 means the stage may start; exit 2 prints the missing artifact and the command that produces it.

## Two kinds of skill

- **Model-invoked** skills you call with the Skill tool: `mattpocock-skills:grilling`, `mattpocock-skills:domain-modeling`, `mattpocock-skills:tdd`, `mattpocock-skills:diagnosing-bugs`, `mattpocock-skills:code-review`, `mattpocock-skills:wizard`, `mattpocock-skills:research`, `mattpocock-skills:prototype`, `mattpocock-skills:codebase-design`, `mattpocock-skills:resolving-merge-conflicts`, `mattpocock-skills:writing-for-agents`, and every `ai-sdlc:sdlc-*` skill.
- **User-invoked** skills only the human can type: `/mattpocock-skills:to-spec`, `/mattpocock-skills:to-tickets`, `/mattpocock-skills:implement`, `/mattpocock-skills:wayfinder`, `/mattpocock-skills:grill-with-docs`, `/mattpocock-skills:triage`, `/mattpocock-skills:handoff`, `/mattpocock-skills:improve-codebase-architecture`, `/mattpocock-skills:setup-matt-pocock-skills`, and every `/ai-sdlc:sdlc-*` command. When the route lands on one of these, stop and tell the human exactly what to type.

## Stages

| # | Stage | Needs | Do | Commits |
| --- | --- | --- | --- | --- |
| 1 | Frame | an idea | `/ai-sdlc:sdlc-start` (calls `grilling` + `domain-modeling`; for a change too big for one session, `/mattpocock-skills:wayfinder`) | `CONTEXT.md` terms, ADRs under `docs/adr/` |
| 2 | Spec | the framed conversation | human types `/mattpocock-skills:to-spec` | spec on the tracker, or `<feature>/spec.md` locally |
| 3 | Tickets | spec | human types `/mattpocock-skills:to-tickets` | tickets with `Blocked by:` edges, `Status: ready-for-agent` |
| 4 | Publish | local spec + tickets, platform is github or azure | `/ai-sdlc:sdlc-publish <feature-dir>` | tracker ids written back, `publish-manifest.json` |
| 5 | Build | `precondition.sh build` exit 0; one unblocked ticket | write `.sdlc/ACTIVE_TICKET` (see below); on a branch, human types `/mattpocock-skills:implement`; drive `tdd` at the agreed seams | commits referencing the ticket id |
| 6 | Review | a diff since the branch point | `mattpocock-skills:code-review` (Skill tool) | review notes on the PR or in the ticket |
| 7 | Verify | review done | `/ai-sdlc:sdlc-verify` runs the `sdlc-verifier` subagent in a fresh context: it runs `commands.verify` in a disposable worktree, never edits anything | `.sdlc/verify/<date>-<sha>.md` with Verdict and Commit lines bound to HEAD (re-verify after every new commit) |
| 8 | Security | verify report | `sdlc-security-auditor` subagent over the diff, ranked per `REVIEW.md` | findings on the PR |
| 9 | PR | verify PASS, findings addressed | `sdlc-platform pr_create <title> <body-file> <base> <head>`; a human code owner approves | the PR |
| 10 | Ship | approved PR, `pr_checks` pass | `/ai-sdlc:sdlc-ship` (release notes, rollback rehearsal, human release authorisation) | `.sdlc/releases/<version>.md`, `.sdlc/release/AUTHORIZED-<sha>` |
| 11 | Learn | a release or an incident | `/ai-sdlc:sdlc-postmortem`, `/ai-sdlc:sdlc-metrics-report` | `.sdlc/postmortems/*.md`, `.sdlc/metrics/*.json` |

Skip nothing between 5 and 10: the hooks make the shortcuts fail (protected paths, test edits under FIX_MODE, production commands without authorisation), so route through the stages instead of around them.

## Active ticket

Before building, record which accepted ticket this work serves:

```
printf '%s\n' "<ticket-id>" > .sdlc/ACTIVE_TICKET
```

The id comes from the ticket file's first line (`<!-- sdlc-publish: id=… -->`) or from the tracker. Confirm the ticket is unblocked with `sdlc-platform work_item_get <id>` and that every blocker listed in its body is `closed`. Delete the file when the PR is opened. With `guardrails.requireTicket` on (tier 2 default), the ticket gate hook denies source edits while this file is missing.

## Bug fixes: FIX_MODE

Fixing a bug follows `mattpocock-skills:diagnosing-bugs`. Once the regression test is red and committed, arm the test guard before touching production code:

```
touch .sdlc/FIX_MODE
```

While the marker exists, edits to test files are denied by hook, so the fix cannot pass by changing the test. Remove the marker after the fix is green and the regression test is unchanged:

```
rm .sdlc/FIX_MODE
```

## Where artifacts live

`.sdlc/features/<slug>/` holds `spec.md`, `issues/NN-*.md` and `publish-manifest.json` (the same layout `to-spec` and `to-tickets` use for the local tracker under `.scratch/<slug>/`). ADRs stay in `docs/adr/`, the glossary in `CONTEXT.md`: both are owned by `domain-modeling`. Verification reports, releases, postmortems and metrics live under `.sdlc/`.

## When the upstream plugin changes

This table was written against `mattpocock-skills` 1.2.3. Before trusting a route after an upstream update, run:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/reuse/check-mattpocock.sh"
```

Exit 1 lists missing, renamed or re-typed skills; treat the affected rows above as stale until `docs/REUSE.md` is updated.
