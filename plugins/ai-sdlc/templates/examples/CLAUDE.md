# usage-digest

## Verify

`pnpm verify` is the one command that proves the code works. Run it before claiming anything is done; paste its last lines as evidence.

## How work flows here

This repo runs the ai-sdlc loop (tier 2, platform azure): grill → spec → tickets → build → review → verify → ship → learn. Ask `ai-sdlc:sdlc-loop` what comes next; it checks the artifacts, not memory. Plan before editing: enter plan mode for anything beyond a one-line change.

- Tickets and specs live under `.sdlc/features/<slug>/`; the tracker workflow is in `docs/agents/issue-tracker.md`.
- Platform operations go through `sdlc-platform` (see `ai-sdlc:sdlc-platform`), never the platform CLI directly.
- Review policy and severity ranking: `REVIEW.md`. Findings are advisory; a human approves every merge on `main`.
- Domain vocabulary: `CONTEXT.md`. Use its terms in code, tests and tickets. Decisions with a "why": `docs/adr/`.
- Secrets are off limits (`.env*`, `secrets/`, cloud credentials); hooks and permission rules enforce it.

## Agent skills

### Issue tracker

Work items are tracked on azure. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: one `CONTEXT.md` at the root and ADRs in `docs/adr/`. See `docs/agents/domain.md`.
