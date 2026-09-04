---
description: "Run the fresh-context verifier (and optionally the security auditor) against the current change; store the report under .sdlc/verify/."
disable-model-invocation: true
argument-hint: "[spec-or-ticket] [--base <ref>] [--security]"
allowed-tools: Bash(git rev-parse *), Bash(git diff *), Bash(git log *), Bash(jq *), Bash(sdlc-platform work_item_get *), Bash(mkdir -p .sdlc/verify), Bash(date *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/loop/validate-report.sh *)
---

Verify the change on the current branch without touching it.

1. Resolve the inputs: the spec or ticket from `$ARGUMENTS` (default: the feature named in `.sdlc/ACTIVE_TICKET`, else ask), the base ref (`--base`, default the default branch from `sdlc.config.json`), and the verification command (`commands.verify`).
2. Spawn the `ai-sdlc:sdlc-verifier` subagent with the Agent tool. Give it: the spec/ticket path or id, the base ref, the verification command, and the instruction to return the report in its documented format. Run it in the foreground and wait.
3. Save the returned report verbatim to `.sdlc/verify/<YYYY-MM-DD>-<short sha>.md` (create the directory). This file is what `precondition.sh ship` and `preflight.sh` read: keep the `**Verdict:**` line (exactly one) and the `**Commit:**` line (exactly one, the sha of HEAD) intact. The ship stage rejects a report whose Commit is not the current HEAD, so re-verify after every new commit. `bash "${CLAUDE_PLUGIN_ROOT}/scripts/loop/validate-report.sh" <file>` confirms the saved file passes.
4. When `--security` is present, also spawn `ai-sdlc:sdlc-security-auditor` with the base ref and save its report to `.sdlc/verify/<YYYY-MM-DD>-<short sha>-security.md`. Keep its `**Commit:**` and `Blocking: <n>` lines intact for the same reason (`validate-report.sh <file> --security` checks them).
5. Report the verdict and the discrepancy list to the user. On `FAIL`, name the next step: fix the code (you, in a normal turn, not the verifier), then run `/ai-sdlc:sdlc-verify` again.
