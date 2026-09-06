---
name: sdlc-ship
description: "Release gates, release note and rollback rehearsal for shipping a change to production. Use when a PR is approved and someone asks to ship, deploy, release or tag it, when a deploy command is denied by the production gate, or when writing .sdlc/releases/<version>.md."
---

# Ship a change

Nothing reaches production on the agent's say-so. The gates are deterministic (`scripts/ship/preflight.sh`), the authorisation is human (`scripts/ship/authorize.sh`), and the production gate hook enforces both on every command listed in `environments.prod.deployCommandPatterns` (the configured production command is always on that list; nothing is gated that the project did not list). `/ai-sdlc:sdlc-ship <pr-id>` drives the procedure.

## Gates, in order

`preflight.sh --pr <id>` prints one JSON verdict: `{head, ready, gates:[{gate, ok, evidence}]}`, exit 0 only when every gate is green.

| Gate | Evidence it reads | Fix when red |
| --- | --- | --- |
| verification report PASS | `.sdlc/verify/*.md` (never `*-security.md`), newest first; the newest report whose `Commit:` is HEAD decides and must be valid: non-empty, exactly one `Verdict:` line, verdict `PASS`, exactly one `Commit:` line whose sha (7 to 40 hex) is a prefix of HEAD. Reports for other commits are skipped; zero or two Verdict lines, a FAIL, a missing Commit line or an empty file are red with a specific reason (`precondition.sh ship` applies the same rule) | `/ai-sdlc:sdlc-verify` after the latest commit |
| security review without Blocking findings | newest `.sdlc/verify/*-security.md`: non-empty, exactly one well-formed `Blocking: <n>` summary line, `n` is 0; when it carries a `Commit:` line that sha must be HEAD (absence is allowed and noted in the evidence). A malformed summary (`Blocking: many`, two summaries, none) is red and is never read as zero findings | `/ai-sdlc:sdlc-verify --security`, then fix the findings |
| working tree clean | `git status --porcelain` is empty | commit or stash |
| human approval on PR | `sdlc-platform pr_get` shows `review_decision: approved` | a code owner approves on the platform; the agent cannot |
| checks pass on PR | `sdlc-platform pr_checks` exits 0 (`status: pass`; 8 is pending); the adapter's `reason`, when present, is appended to the evidence | wait, or fix CI |
| release authorised for HEAD | `.sdlc/release/AUTHORIZED-<HEAD sha>` exists and is complete: `authorised_by=`, `authorised_at=`, `expires=` and `commit=` each exactly once, the identity and timestamp non-empty, `expires=` digits only and strictly in the future, `commit=` a full 40-hex sha equal to HEAD and to the sha in the file name. Anything else (empty file, duplicated key, `expires=tomorrow`, an expired marker, a sha mismatch) is red with the reason | a human runs `authorize.sh` (below) |

Without `--pr` the approval and checks gates are replaced by one failing gate `pull request named`, so always pass the id.

The report rules live in one place, `scripts/loop/_reports.sh`, and the marker rules in `scripts/ship/_authz.sh`; `precondition.sh ship`, `preflight.sh` and the `gate-production` hook source them, so the three never disagree. `scripts/loop/validate-report.sh <file> [--security] [--head <sha>]` is the read-only command-line form of the report validator (exit 0 valid, 1 with the reason on stderr): CI runs it on a saved report, and the verifier may run it on its own output. Without `--head` it uses the HEAD of the repository containing the file.

## Why authorisation is human-only

`authorize.sh` exits 2 when `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT` or `CLAUDE_PROJECT_DIR` is set, so it cannot run from a Bash tool call. `.sdlc/release/**` is one of the two paths `guard-protected-paths` always protects (no unlock marker releases it), so the agent cannot write the marker by hand either. The marker (`authorised_by`, `authorised_at`, `expires`, `expires_at`, `commit`) is bound to one full sha and expires (default 120 minutes, `--ttl-minutes`), so a new commit or a stale session closes the gate again. `gate-production.sh` validates the marker for `HEAD` with the rules in the table above before any command matching `environments.prod.deployCommandPatterns` and denies with the validator's reason otherwise; a marker it cannot parse is a denial, not a pass. Ask the human to run, in their own terminal:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ship/authorize.sh" --sha <HEAD sha> --ttl-minutes 120 --by <name>
```

## Release note (`templates/artifacts/release.md.tmpl`)

Rendered with `scripts/init/render.sh` into `.sdlc/releases/<version>.md`; every `RELEASE_*` marker is passed as `--var`, and rendering fails if one is missing. `REPO_DEFAULT_BRANCH` and `COMMANDS_VERIFY` come from the config.

| Marker | Source |
| --- | --- |
| `RELEASE_VERSION`, `RELEASE_DATE`, `RELEASE_SHA` | the tag being cut, today, `git rev-parse HEAD` |
| `RELEASE_AUTHORISED_BY` | `authorised_by=` line of the marker (write `pending` before authorisation) |
| `RELEASE_VERIFY_REPORT` | path of the PASS report |
| `RELEASE_CHANGES` | `git log <previous tag>..HEAD --oneline`, one bullet per PR or ticket id |
| `RELEASE_REVIEW_EVIDENCE` | PR url and `review_decision` from `pr_get` |
| `RELEASE_SECURITY_EVIDENCE` | security report path and its Blocking/Important counts |
| `RELEASE_APPROVAL_EVIDENCE` | approver and time from the platform |
| `RELEASE_CHECKS_EVIDENCE` | check names and statuses from `pr_checks` |
| `RELEASE_PREVIOUS`, `RELEASE_ROLLBACK_COMMAND`, `RELEASE_ROLLBACK_REHEARSED`, `RELEASE_ROLLBACK_ENV`, `RELEASE_MIGRATIONS` | the rollback rehearsal below |
| `RELEASE_WATCH` | the dashboards, logs or alerts to watch, and for how long |

## Rollback rehearsal

Ask these before authorisation and write the answers, not assumptions:

1. Previous good release: tag or sha that is known to run in production now.
2. Rollback command: the exact command that redeploys it (the same deploy command with the previous sha, or the platform's redeploy). It matches the production patterns too, so it needs its own authorisation when the time comes.
3. Rehearsed: was the rollback command run against staging (`environments.staging`) for this release? Record the date and environment, or `not rehearsed`.
4. Data migrations: none, backward-compatible, or irreversible; for irreversible ones name the restore procedure.
5. Watch: what signal shows the release is healthy, and who is watching.

Before handing a release branch to someone else, `/mattpocock-skills:handoff` compacts the context for them.
