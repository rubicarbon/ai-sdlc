# `.dev/` — build-session controls for this repository

This directory holds material for developing `ai-sdlc-kit` itself. Nothing here ships in the plugin.

## Repository boundary: a convention only

Sessions working on this repo should stay inside the repo root. **Nothing enforces that.** `.claude/settings.json` carries no path restrictions; earlier revisions had a `PreToolUse` hook and then a set of `Read`/`Edit` deny rules, and both were removed as dev-only weight.

Two consequences worth keeping in mind:

- The Claude Code scratchpad directory offered by the harness lives outside the repo. Prefer `.dev/scratch/` (gitignored) so throwaway material stays with the repo.
- Reading the diff before committing is the only control. `git status` and `git diff` are load-bearing here, not ceremony.

## Scratch space

`.dev/scratch/` is gitignored and holds `/sdlc-init` dry-run repositories, adapter mock output and other throwaway material.

## `VERIFY.md`

Steps that only the repository owner can run (plugin install from the marketplace, `claude --debug-file` hook registration check, unrelated-repo silence check) are written to `.dev/VERIFY.md` with exact commands and expected output.
