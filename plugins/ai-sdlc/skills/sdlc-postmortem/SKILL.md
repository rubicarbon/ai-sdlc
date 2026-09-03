---
name: sdlc-postmortem
description: "Blameless postmortem procedure for production incidents and escaped defects. Use after an incident, a rollback, a failed deployment or a Sev ticket, when asked what went wrong, or when writing .sdlc/postmortems/*.md and its action items."
---

# Postmortem

A postmortem exists to change the system, not to find who was wrong. Its output is a document under `.sdlc/postmortems/<date>-<slug>.md` (from `templates/artifacts/postmortem.md.tmpl`), a set of action items on the tracker, and one fact for the metrics: the stage where the defect should have been caught. `/ai-sdlc:sdlc-postmortem` drives the procedure.

## Blameless rules

- Name systems, decisions, signals and stages. Never name a person as a cause; the `Author` field is the only name in the document.
- Every cause is phrased as a missing or ignored signal ("no test covered the empty-cart path", "the verifier had no criterion for the migration"), not as an error someone made.
- "Human error" is not a cause. Ask what made the wrong action easy and the right one hard.
- Write what went well with the same care as what failed; it tells you which guardrails to keep.

## Timeline sources

Every row of the timeline table cites where it came from:

| Source | Call | Gives |
| --- | --- | --- |
| Incident ticket | `sdlc-platform work_item_get <id>` | `created_at` (detection), `closed_at` (recovery), labels, body |
| Offending change | `sdlc-platform pr_get <pr>` | `created_at`, `merged_at`, `review_decision`, size (`null` on Azure) |
| Release | `.sdlc/releases/<version>.md` | authorised by, gates passed, rollback plan and whether it was rehearsed |
| Commits | `git log --since --until --format='%H %cI %s'` | deploys, reverts (`Revert` prefix), hotfixes |
| People | the interview | what was seen, when, and what was decided |

Duration is detection to recovery, in UTC. When a source is unavailable (platform `none`), the row says `human` and the postmortem says the time is self-reported.

## Cause interview

Call the Skill tool with `mattpocock-skills:grilling` and keep it on four threads: the missing signal, the stage that should have caught it, what slowed recovery, what worked. Use `mattpocock-skills:research` when a cause is a dependency or a platform behaviour that needs a primary source. The interview ends when every cause has at least one action.

## Action types

| Type | Meaning | Examples in this plugin |
| --- | --- | --- |
| guardrail | makes the failure impossible by construction | a `guardrails.protectedPaths` entry, a `deployCommandPatterns` entry, a deny rule in `.claude/settings.json`, a required check |
| verification | catches it before ship | a regression test, an acceptance criterion the `sdlc-verifier` must exercise, a `REVIEW.md` item for the security auditor |
| process | a stage or artifact that was skipped | "no verify report", "shipped without rehearsal", "ticket had no acceptance criteria" |

Prefer guardrail over verification over process: a process action depends on people remembering. Each action becomes a work item (`sdlc-platform work_item_create`) labelled `postmortem-action` (never the incident label, which `metrics_export` counts as an incident), linked to the incident (`work_item_link --type related`), with the returned id in the table.

## Defect escape stage

Pick one stage from the loop: spec, tickets, build, review, verify, security, PR approval, ship, monitoring. It answers "which existing gate had the information to stop this and did not". Record it in `INCIDENT_ESCAPED_STAGE`; repeated stages across postmortems show where the loop is weakest.

## How it feeds metrics

`sdlc-platform metrics_export` counts items labelled `metrics.incidentLabel` as incidents: they drive MTTR (open to close) and the defect escape rate (incidents over successful deployments) in `report.py`. An incident without that label is invisible to the report, so confirm the label before closing the postmortem. The `retro` skill upstream (not shipped) covers agent-environment learnings; this one covers production.
