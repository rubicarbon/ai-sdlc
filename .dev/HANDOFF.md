# Build handoff (paused 2026-09-03, resume 20:00 local)

## State

Committed: phases 0 to 6 (`git log --oneline`). Uncommitted, in progress: phase 7 batch A (init engine, schema validator, ship scripts, settings fragments, domain template, evals `config-validate` and `init-dry-run`).

`config-validate` passes. `init-dry-run` fails on these points, all in `plugins/ai-sdlc/scripts/init/run.sh`:

1. Re-run is not reported as `already-initialised`: `claude_md()` rewrites CLAUDE.md on every run (the block-append path counts as a write). Compare the would-be content with the file and count `unchanged` when identical.
2. `--check` exits 1 when a managed file is `user-edited`; the test expects user edits to be the user's business (exit 0) and only `template-changed` / `missing` to count as drift. Adjust the `pending` filter for `--check`.
3. Azure render fails: `issue-tracker-azure.md.tmpl` needs `AZURE_WORK_ITEM_TYPE`; `run.sh` does not set `azure.workItemType` in the generated config. Default it to `User Story` in the config builder (or pass `--var AZURE_WORK_ITEM_TYPE=...` when rendering).
4. `--tier 9` should be a usage error (exit 2) but validation happens after config build; validate `--tier` before building. `run.sh` on a non-git dir exits 2 (cd failure) where the test expects 1; either is acceptable, align the test or the script.
5. The settings deny-rule assertion fails only because of a `jq` predicate quirk in the eval (`index(...) and index(...)`); check `.permissions.deny` contains both rules with `IN`/`any`.

## Paused workflow

Workflow `ai-sdlc-authoring` (run id `wf_00f5834e-a98`) was stopped before its writers finished. Resume it with the script at
`C:\Users\gergely.somogyvari\.claude\projects\C--Projects-ai-sdlc\3ef25487-f7cc-4660-b02c-1b4c5e261f7c\workflows\scripts\ai-sdlc-authoring-wf_00f5834e-a98.js`
using `resumeFromRunId: wf_00f5834e-a98`. It authors: commands `sdlc-init`, `sdlc-status`, `sdlc-upgrade`, `sdlc-ship`, `sdlc-postmortem`, `sdlc-metrics-baseline`, `sdlc-metrics-report`; skills `sdlc-ship`, `sdlc-postmortem`, `sdlc-metrics`; `docs/ARCHITECTURE.md`, `docs/SECURITY.md`, `docs/ADOPTION.md`, `docs/METRICS.md`; root `README.md`, plugin `README.md`, `.dev/VERIFY.md` v2; then a verifier agent. Check `git status` first: some writers may have written files before the stop.

## Remaining after that

- Phase 7: fix the five points above, rerun `bash plugins/ai-sdlc/evals/run.sh`, commit.
- Phase 8: review the workflow's docs against the code, commit.
- Phase 9: end-to-end dry run in `.dev/scratch/` (init github and azure, publish fixture spec to mock Azure with edges, write-back), acceptance checklist, placeholder scan, side-by-side skill list, final report, `.dev/VERIFY.md` v2 hand-over to the owner. shellcheck: the owner installs it before the final acceptance pass.
