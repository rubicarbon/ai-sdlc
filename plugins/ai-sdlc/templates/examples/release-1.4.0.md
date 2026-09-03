# Release 1.4.0

- **Date:** 2026-08-02
- **Commit:** `aaa111aaa111aaa111aaa111aaa111aaa111aaa1` on `main`
- **Authorised by:** release manager (Boards approval on PR 230, release authorisation 2026-08-02 11:52 UTC)
- **Verification report:** `.sdlc/verify/2026-08-02-aaa111a.md`

## Changes

- Nightly digest: aggregate counters per region in one batch (ticket 4650, PR 230)
- Opt-out toggle in account settings (ticket 4651, PR 231)

## Gates passed

| Gate | Evidence |
| --- | --- |
| Verify command | `pnpm verify` passed in the verifier's fresh context |
| Code review | `mattpocock-skills:code-review` on PR 230 and 231: 0 Blocking, 2 Important resolved |
| Security audit | `sdlc-security-auditor`: 0 Blocking, 1 Nit |
| Human approval | 1 approval by a required reviewer on each PR |
| Checks | `sdlc-platform pr_checks 230`: pass (build, minimum reviewers, work item linking) |

## Rollback rehearsal

- **Previous good release:** 1.3.2 (`999fff999fff999fff999fff999fff999fff999f`)
- **Rollback command:** `az pipelines run --name sdlc-deploy --branch release/1.3.2`
- **Rehearsed on:** 2026-08-01 (target environment staging)
- **Data migrations:** none in this release; the digest table is additive

## Watch after release

Aggregation job duration per region, send count per region against the previous day, support tickets mentioning "digest" for 48 hours.
