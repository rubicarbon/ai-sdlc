# Postmortem: Nightly digest not sent to 1,240 accounts

- **Date of incident:** 2026-08-03
- **Severity:** S2 (customer-visible, no data loss)
- **Duration (detection to recovery):** 6h 30m
- **Author:** platform team, written 2026-08-05
- **Related:** ticket 4711, release 1.4.0

This document is blameless. It names systems, decisions and missing signals, never people.

## What happened

Release 1.4.0 changed the aggregation job to write counters in one batch per region. The EU batch exceeded the database statement timeout, the job logged the error and exited 0, and the send step ran with an empty digest table for EU accounts. No email went out for 1,240 accounts; 3 owners reported it before monitoring did.

## Timeline (UTC)

| Time | Event | Source |
| --- | --- | --- |
| 02:00 | Aggregation job starts; EU batch times out after 30 s, logged at WARN | job logs |
| 02:04 | Send step completes; 1,240 EU accounts skipped as "no data" | send logs |
| 07:40 | First owner report via support | ticket 4711 |
| 08:10 | Incident opened; `Revert "Batch aggregation per region"` merged | PR 233 |
| 08:30 | Job re-run for 2026-08-02 completes; emails sent | job logs |

## Impact

1,240 of 9,800 account owners received no digest for 2026-08-02. No data was lost; the re-run delivered the same numbers six hours late.

## Why it happened

- The batch rewrite changed the failure mode from "one account fails" to "one region fails", and the job kept the old exit-0-on-warning behaviour.
- The verifier ran the fixture day (12 accounts, one region); nothing exercised a batch larger than the statement timeout.
- The send step treats "no row" and "zero activity" identically.

## What went well

The revert was a single PR with a ready rollback command from the release note, and the job's idempotency made the re-run safe.

## What we change

| Action | Type | Owner | Ticket |
| --- | --- | --- | --- |
| Job exits non-zero when any region batch fails; send step refuses to run after a failed aggregation | guardrail | platform | 4720 |
| Verifier fixture includes a region above the statement timeout threshold | verification | platform | 4721 |
| Send step distinguishes "no row" from "zero activity" and alerts on missing rows | verification | notifications | 4722 |

Action types: **guardrail** (a hook, permission rule or CI check that makes the failure impossible), **verification** (a test or verifier criterion that catches it), **process** (a stage or artifact that was skipped). Prefer guardrails and verification over process.

## Defect escape

Stage where this defect should have been caught: verify (acceptance criterion "re-running the job for the same day is idempotent" was checked; "a batch failure fails the job" was never a criterion). Counted in the metrics report as a defect escape for release 1.4.0.
