# `.dev/` — build-session controls for this repository

This directory holds material for developing `ai-sdlc-kit` itself. Nothing here ships in the plugin.

## Repository boundary restriction

Sessions working on this repo should stay inside the repo root. **Permission deny rules** in `.claude/settings.json` deny `Read`/`Edit` on the home directory, `C:\Users`, `/tmp`, Windows system directories and the `D:` drive. Rules cannot express "everything except this repo" (deny beats allow, no negation), so they only name known outside roots.

### Known limits

- The rules name outside roots explicitly, so a path outside the repo that is not one of those roots is not denied.
- The Claude Code scratchpad directory offered by the harness lives outside the repo. Prefer `.dev/scratch/` (gitignored) so throwaway material stays with the repo.

## Scratch space

`.dev/scratch/` is gitignored and holds `/sdlc-init` dry-run repositories, adapter mock output and other throwaway material.

## `VERIFY.md`

Steps that only the repository owner can run (plugin install from the marketplace, `claude --debug-file` hook registration check, unrelated-repo silence check) are written to `.dev/VERIFY.md` with exact commands and expected output.
