# `.dev/` — build-session controls for this repository

This directory holds material for developing `ai-sdlc-kit` itself. Nothing here ships in the plugin.

## Repository boundary: a convention, not an enforced boundary

Sessions working on this repo should stay inside the repo root. That is a convention. The only mechanism behind it is a set of **permission deny rules** in `.claude/settings.json`, which deny `Read`/`Edit` on the home directory, `C:\Users`, `/tmp`, Windows system directories and the `D:` drive (some of those roots are `Read`-only entries, with no matching `Edit` rule). Rules cannot express "everything except this repo" (deny beats allow, no negation), so they only name known outside roots.

Treat the rules as a guard against accidental reads and edits in the obvious places. They do not confine a session to the repository.

### Known gaps

- **Paths.** The rules name outside roots explicitly, so any outside path that is not one of those roots is not denied.
- **Tools.** The rules name `Read` and `Edit`. `Write` is evaluated against the `Edit` rules, so it is denied wherever an `Edit` entry exists — but not on the roots listed for `Read` only. `Glob`, `Grep` and the `Bash`/`PowerShell` tools are not covered at all, and shell commands can read or modify anything the user account can.
- **Scratchpad.** The Claude Code scratchpad directory offered by the harness lives outside the repo. Prefer `.dev/scratch/` (gitignored) so throwaway material stays with the repo.

Closing the tool-level gaps would need a `PreToolUse` hook; one existed in an earlier revision and was removed as dev-only weight. Nothing here is a substitute for reviewing what a session actually did before committing.

## Scratch space

`.dev/scratch/` is gitignored and holds `/sdlc-init` dry-run repositories, adapter mock output and other throwaway material.

## `VERIFY.md`

Steps that only the repository owner can run (plugin install from the marketplace, `claude --debug-file` hook registration check, unrelated-repo silence check) are written to `.dev/VERIFY.md` with exact commands and expected output.
