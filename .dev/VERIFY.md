# VERIFY.md: steps only the repository owner can run

The build session could not install the plugin locally (no access outside the repo) and could not open another repository. These steps prove installation and runtime registration. Run them from a normal Claude Code terminal. Expected output is given for each step; anything else is a finding to report back.

Section 7 lists the behaviour that this build verified only against mocks or by reading source, with the command that proves each one on a real project.

## 0. Prerequisites

```bash
claude --version          # expected: 2.1.224 or newer
jq --version              # expected: jq-1.7 or newer (hooks and adapters depend on jq)
git --version
```

## 1. Validate the manifests (same check the build ran)

From the repository root:

```bash
claude plugin validate . --strict
claude plugin validate plugins/ai-sdlc --strict
```

Expected, twice:

```
✔ Validation passed
```

## 2. Add the marketplace from the local checkout and install

Inside a Claude Code session started in **any** directory:

```
/plugin marketplace add C:\Projects\ai-sdlc
```

Expected: a confirmation naming the marketplace `ai-sdlc-kit` with one plugin, `ai-sdlc`. Then:

```
/plugin install ai-sdlc@ai-sdlc-kit
```

Expected: install succeeds and asks you to restart (or run `/reload-plugins`). After restart:

```bash
claude plugin list
```

Expected: a line containing `ai-sdlc@ai-sdlc-kit` marked enabled, version `0.1.0` (the version in `plugins/ai-sdlc/.claude-plugin/plugin.json` at the time you installed).

Alternative for a quick check without touching the marketplace registry:

```bash
claude --plugin-dir C:\Projects\ai-sdlc\plugins\ai-sdlc
```

## 3. Confirm the components registered

```bash
claude plugin details ai-sdlc@ai-sdlc-kit
```

Expected: every entry below, each namespaced `ai-sdlc:`. The list matches the directories `plugins/ai-sdlc/commands`, `skills`, `agents` and the matcher groups in `plugins/ai-sdlc/hooks/hooks.json`.

| Kind | Names |
| --- | --- |
| commands | `sdlc-init`, `sdlc-status`, `sdlc-upgrade`, `sdlc-start`, `sdlc-publish`, `sdlc-verify`, `sdlc-ship`, `sdlc-postmortem`, `sdlc-metrics-baseline`, `sdlc-metrics-report` |
| skills | `sdlc-loop`, `sdlc-platform`, `sdlc-publish`, `sdlc-ship`, `sdlc-postmortem`, `sdlc-metrics`, `sdlc-security-review` |
| agents | `sdlc-verifier`, `sdlc-security-auditor`, `sdlc-metrics-analyst` |
| hooks | `PreToolUse` × 4 matcher groups (6 hook scripts), `PostToolUse` × 1 matcher group (1 hook script) |

In an interactive session, typing `/ai-sdlc:` should autocomplete the commands and skills above.

## 4. Confirm every hook registers with `${CLAUDE_PLUGIN_ROOT}` resolved

The seven hook scripts in `plugins/ai-sdlc/hooks/` are `guard-secrets.sh`, `guard-protected-paths.sh`, `guard-verifier-readonly.sh`, `guard-test-edits.sh`, `guard-ticket-gate.sh`, `gate-production.sh` and `post-edit-verify.sh`.

You need an **sdlc project**: any repo where you ran `/ai-sdlc:sdlc-init`, or a throwaway one made with the init engine directly:

```bash
mkdir -p C:\Projects\ai-sdlc\.dev\scratch\gh && cd C:\Projects\ai-sdlc\.dev\scratch\gh && git init -q
bash C:\Projects\ai-sdlc\plugins\ai-sdlc\scripts\init\run.sh --platform none --tier 1 --team solo --verify "true" --yes
```

Expected: one JSON line on stdout with `"result":"init"` and a `files` list; `sdlc.config.json` now exists in that directory. Running the same command again prints `"result":"already-initialised"`.

Start a session there with a debug file, ask for one harmless edit, then exit:

```bash
cd C:\Projects\ai-sdlc\.dev\scratch\gh
claude --debug-file .sdlc-debug.txt -p "Append the line 'verify' to NOTES.md and stop."
grep -E 'guard-secrets|guard-protected-paths|guard-verifier-readonly|guard-test-edits|guard-ticket-gate|gate-production|post-edit-verify' .sdlc-debug.txt | head -20
grep -c 'CLAUDE_PLUGIN_ROOT}' .sdlc-debug.txt
```

Expected:

- The first `grep` prints hook lines for all seven script names whose paths start with an absolute path under `C:\Users\<you>\.claude\plugins\cache\ai-sdlc-kit\ai-sdlc\<version>\hooks\` (or the `/c/Users/...` spelling).
- The second `grep` prints `0`: no line still contains the literal, unexpanded `${CLAUDE_PLUGIN_ROOT}`.
- No line reads `hook error` or `No such file or directory`.

Delete `.sdlc-debug.txt` afterwards; it can contain file contents.

## 5. Confirm an unrelated repo produces zero hook output and no startup delay

Pick any repository that has **no** `sdlc.config.json`.

```bash
cd C:\Projects\<some-unrelated-repo>
claude --debug-file .sdlc-debug.txt -p "Append the line 'verify' to NOTES.md, then delete that line again, and stop."
grep -E 'hook error|BLOCKED|sdlc' .sdlc-debug.txt | grep -v 'ai-sdlc-kit\\ai-sdlc\\' | head
```

Expected: the `grep` prints nothing. The transcript shows no hook messages of any kind. Every `ai-sdlc` hook exits 0 before reading its input because `sdlc.config.json` is absent.

Startup delay: run each command three times and compare the wall clock.

```bash
time claude -p "reply with the single word ok"
claude plugin disable ai-sdlc@ai-sdlc-kit
time claude -p "reply with the single word ok"
claude plugin enable ai-sdlc@ai-sdlc-kit
```

Expected: the difference between enabled and disabled is within run-to-run noise (well under one second). Hooks do not run at startup; they run per tool call, and in a non-sdlc repo each exits in the time it takes bash to start.

## 6. Uninstall (to leave your machine as it was)

```
/plugin uninstall ai-sdlc@ai-sdlc-kit
/plugin marketplace remove ai-sdlc-kit
```

Expected: both succeed; `claude plugin list` no longer shows `ai-sdlc`.

## 7. Not live-verified in this build

Everything below passed `plugins/ai-sdlc/evals/run.sh` and `scripts/platform/conformance.sh` against the fake `gh` and `az` in `plugins/ai-sdlc/scripts/platform/_mocks/bin`, or was read from upstream source, but never ran against a real service. Each item names the command that proves it on a real project. Run the Azure items in a checkout whose `origin` is an Azure Repos remote with `sdlc.config.json` set to `"platform":"azure"` and `az login` plus `az devops configure --defaults organization=... project=...` done; run the GitHub items in a checkout with a GitHub remote and `gh auth status` passing.

### 7.1 Azure relation type names (`Successor`, `Predecessor`, `Parent`, `Related`)

`scripts/platform/azure/work_item_link.sh` calls `az boards work-item relation add --relation-type Successor` for `blocks`, `Parent` for `parent` and `Related` for `related`. The mock accepts any name.

```bash
sdlc-platform work_item_create "verify A" /dev/null
sdlc-platform work_item_create "verify B" /dev/null
sdlc-platform work_item_link <idA> <idB> --type blocks
az boards work-item relation show --id <idB> -o json | jq '.relations[].rel'
```

Expected: the link call prints `{"from":"<idA>","to":"<idB>","type":"blocks","native":true,"platform":"azure"}`; the `relations` list of B contains `"System.LinkTypes.Dependency-Reverse"` (Predecessor) and A's contains `"System.LinkTypes.Dependency-Forward"` (Successor). Repeat the link call: expected exit 0 and the same JSON (idempotent). Then `--type parent` and `--type related`: expected `System.LinkTypes.Hierarchy-Forward` / `Hierarchy-Reverse` and `System.LinkTypes.Related`. If `az` rejects a relation type name, the finding is the exact error text.

### 7.2 `az repos policy` subcommand flags

`scripts/platform/azure/branch_protect_apply.sh` runs `az repos policy list --branch`, then `approver-count create --minimum-approver-count`, `required-reviewer create --required-reviewer-ids`, `work-item-linking create`, `comment-required create` and, when a pipeline is registered, `build create --build-definition-id`.

```bash
sdlc-platform --dry-run branch_protect_apply main      # prints the az commands, changes nothing
sdlc-platform branch_protect_apply main
sdlc-platform branch_protect_apply main
az repos policy list --branch main -o table
```

Expected: the first real run prints a JSON with `applied` non-empty; the second prints the same policies under `unchanged` and `applied` as `[]`; `skipped` lists at most the `build` policy with the reason that the pipeline is not registered. The table lists Minimum number of reviewers, Required reviewers (when `azure.requiredReviewers` is set), Work item linking and Comment requirements policies on `refs/heads/main`. Any `unrecognized arguments` error from `az` is a finding.

### 7.3 `az rest` thread POST for PR comments

`scripts/platform/azure/pr_comment.sh` posts a thread with `az rest --method post --uri .../pullRequests/<id>/threads?api-version=...`.

```bash
printf 'verify comment\n' > .dev/scratch/c.md
sdlc-platform pr_comment <pr-id> .dev/scratch/c.md
```

Expected: `{"id":"<pr-id>","comment_id":"<number>","platform":"azure"}` (the contract allows `null` for `comment_id`) and the comment is visible on the PR in the browser. Exit 1 with `ai-sdlc: az rest POST threads failed:` is a finding; include the first 300 characters it prints.

### 7.4 `az pipelines create --skip-first-run true`

`scripts/platform/azure/ci_workflow_install.sh` registers each rendered pipeline with `az pipelines create --name <n> --yml-path .azuredevops/pipelines/<n>.yml --repository <repo> --repository-type tfsgit --branch <default> --skip-first-run true` unless `az pipelines list --name <n>` already finds it. The YAML must be pushed to the default branch first.

```bash
sdlc-platform ci_workflow_install
git add .azuredevops && git commit -m "ci: sdlc pipelines" && git push
sdlc-platform ci_workflow_install
az pipelines list -o table
```

Expected: the first call prints the three pipeline files under `installed` and `registered` as `[]` or an error telling you to push first; the second prints them under `unchanged` and `registered` lists `sdlc-pr-review`, `sdlc-deploy`, `sdlc-evals`; the table shows the three pipelines with no run started. A `--skip-first-run` flag rejection is a finding.

### 7.5 GitHub issue dependencies API and sub-issues API

`scripts/platform/github/work_item_link.sh` calls `POST repos/{o}/{r}/issues/{to}/dependencies/blocked_by` with `issue_id=<database id>` for `blocks` and `POST repos/{o}/{r}/issues/{from}/sub_issues` with `sub_issue_id` for `parent`; on 403/404 it falls back to a `Blocked by: #n` body line and reports `"native":false`.

```bash
sdlc-platform work_item_create "verify A" /dev/null
sdlc-platform work_item_create "verify B" /dev/null
sdlc-platform work_item_link <idA> <idB> --type blocks
gh api repos/<owner>/<repo>/issues/<idB>/dependencies/blocked_by --jq '.[].number'
sdlc-platform work_item_link <idA> <idB> --type parent
gh api repos/<owner>/<repo>/issues/<idA>/sub_issues --jq '.[].number'
```

Expected: both link calls print `"native":true`; the two `gh api` calls print `<idA>` and `<idB>` respectively. `"native":false` on a repository where the feature is enabled is a finding; `"native":false` with a `Blocked by: #<idA>` line appended to issue B is the documented fallback where the API is unavailable.

### 7.6 `claude-code-action` inputs `plugins` and `plugin_marketplaces`

`templates/github/workflows/sdlc-pr-review.yml` passes `plugin_marketplaces` and `plugins` to `anthropics/claude-code-action@v1`. These input names were read from the action's `action.yml`, not executed.

```bash
curl -s https://raw.githubusercontent.com/anthropics/claude-code-action/v1/action.yml | grep -E '^  (plugins|plugin_marketplaces|claude_args|use_sticky_comment|track_progress|anthropic_api_key|github_token):'
```

Expected: six lines, one per input name. Then, on a tier 3 GitHub project with `ANTHROPIC_API_KEY` set as a repository secret, open a non-draft pull request.

Expected: the `sdlc-pr-review` run finishes green, posts one sticky comment ending with `Advisory review by ai-sdlc; a human code owner approves.`, and the job summary contains an `ai-sdlc review cost` table with a cost at or below `cost.maxBudgetUsd`. An `Unexpected input(s)` warning naming `plugins` or `plugin_marketplaces` is a finding.

### 7.7 shellcheck

shellcheck was not installed on the build machine; the `sdlc-evals` CI templates install it on ubuntu and run it with `-S warning`. Locally:

```bash
cd C:\Projects\ai-sdlc\plugins\ai-sdlc
shellcheck -S warning hooks/*.sh scripts/*.sh scripts/*/*.sh scripts/platform/*/*.sh bin/sdlc-platform
```

Expected: no output and exit 0. Any `SC` code printed is a finding; `scripts/platform/azure/_md2html.awk` is awk and is not in the list.
