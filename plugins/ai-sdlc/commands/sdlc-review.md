---
description: "Advisory review of one pull request in a fresh session (review.runner local): security audit by the sdlc-security-auditor over the exact PR head in an isolated worktree, spec compliance, one report saved under .sdlc/verify/ and posted on the PR."
disable-model-invocation: true
argument-hint: "[--pr <id>] [--base <ref>] [--launch <id>]"
allowed-tools: Bash(git rev-parse *), Bash(git diff *), Bash(git log *), Bash(git show *), Bash(git merge-base *), Bash(git branch *), Bash(jq *), Bash(sdlc-platform pr_get *), Bash(sdlc-platform work_item_get *), Bash(mkdir -p .sdlc/verify), Bash(date *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/review/*), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/loop/validate-report.sh *)
---

Review the pull request named in `$ARGUMENTS`. You are the reviewer, not the author: this session was opened by the `launch-local-review` hook (or by the human) so that the review runs in a fresh context. You modify no project file except the report under `.sdlc/verify/` and the launch state under `.sdlc/tmp/review/`; you never approve or request changes on the platform; findings are advisory and a human code owner approves.

Every step below goes through the scripts in `${CLAUDE_PLUGIN_ROOT}/scripts/review/`; they record the launch state that the author session and `/ai-sdlc:sdlc-status` read.

1. **Inputs.** `--launch <id>` is the launch this session belongs to; without it create one so the run is tracked:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/review/status.sh" new --branch "$(git branch --show-current)" --pr <id> --trigger manual
   ```

   Then `status.sh set <launch> running`. On GitHub or Azure DevOps `--pr <id>` is required (ask when missing). `sdlc-platform pr_get <id>` gives `head_sha`, `base_sha`, `head`, `base`, `head_repo_url`, `title`, `body`, `url`; attach them: `status.sh attach <launch> --pr <id> --head-sha <head_sha> --base-sha <base_sha>`. On platform `none` there is no pull request: `--base <ref>` (default `repo.defaultBranch` from `sdlc.config.json`) and the local HEAD are reviewed.

2. **Snapshot.** Never read the author's checkout. Create the isolated worktree of the exact head:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/review/snapshot.sh" --launch <launch> --pr <id> --head-sha <head_sha> --base-sha <base_sha> --head-repo-url <url> --head-ref <head>
   ```

   (platform `none`: `snapshot.sh --launch <launch> --local --base <ref>`). It prints `{dir, head_sha, base_sha}`. Exit 3 means the pull request moved while you were starting: the state is `failed head-moved`; stop and say so (the next push launches a new review). Exit 5 means another launch is reviewing this PR and head: the state is `skipped duplicate`; stop and name that launch.

3. **Security audit.** Spawn the `ai-sdlc:sdlc-security-auditor` subagent with the Agent tool, in the foreground, and give it: the worktree `dir` as its working directory, the diff to audit (`git -C <dir> diff <base_sha>...<head_sha>`, full shas, never branch names), the PR title and body, the ticket id when visible (`#123` or `AB#123`), and the instruction to return its report in the `sdlc-security-review` format (it may include its own summary and Commit lines; `assemble.sh` normalises them). Save its text verbatim to `.sdlc/tmp/review/wt-<launch>.security.md`.

4. **Spec compliance.** Find the ticket id in the title, body or head branch; the spec or ticket lives in the worktree under `.sdlc/features/**` or `.scratch/**`, else `sdlc-platform work_item_get <id>`. Compare the same diff against its requirements and write `.sdlc/tmp/review/wt-<launch>.spec.md` with three sections, one bullet per finding in the shape `` - `path:line` (requirement): what is wrong. Fix: <smallest change>. ``:

   ```
   ## Missing
   ## Partial
   ## Not asked for
   ```

   Use `- none` for an empty section. When no spec or ticket can be found write `## No spec found` with one sentence; that is a gap, not a pass. Missing requirements count as Blocking, partial ones and unrequested work as Important.

5. **Assemble.** One report, one summary line that sums security and spec findings:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/review/assemble.sh" --security .sdlc/tmp/review/wt-<launch>.security.md --spec .sdlc/tmp/review/wt-<launch>.spec.md \
     --head <head_sha> --base <base_sha> --pr <id> --cap <review.nitCap> --title "PR <id>: <title>" --out .sdlc/tmp/review/wt-<launch>.report.md
   ```

   Then `status.sh set <launch> saved`. The report is not published yet.

6. **Finalize.** Validate, re-check the head, post, publish:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/review/finalize.sh" --launch <launch> --report .sdlc/tmp/review/wt-<launch>.report.md \
     --publish .sdlc/verify/<YYYY-MM-DD>-<head_sha first 12>-pr<id>-security.md --pr <id> --head-sha <head_sha>
   ```

   (platform `none`: no `--pr`, publish to `.sdlc/verify/<date>-<sha12>-local-security.md`; the end state there is `saved`.) Exit 0: the state is `posted`, the comment id and the published path are printed. Exit 1: the state already says `failed validate: …` (fix the report format and run finalize again) or `failed post: …` (retry; the report stays at the tmp path); report the reason and leave the state failed rather than pretending. Exit 4: the head moved while you reviewed; the tmp report is marked stale and nothing is published; the next push launches a new review. Never copy a report into `.sdlc/verify/` by hand: only finalize publishes, and only after validation and posting succeeded.

7. **Clean up and report.** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/review/snapshot.sh" --cleanup --launch <launch>`. Tell the user: the Blocking / Important / Nit counts, the published path, the comment URL or id, the final state, and that a new commit needs a new review (the report is bound to `head_sha`). Do not approve or request changes; do not edit code; if a finding needs fixing, the author fixes it and pushes, which launches the next review.
