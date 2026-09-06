# VERIFY.md: what this build verified, how, and what remains mock-only

Two kinds of checks are listed here. Section A is what the repair session ran on the build
machine (Windows 11, Git Bash, jq 1.8.2, Python 3.10, Claude Code 2.1.224) with the exact
command and the observed result. Section B lists the steps only the repository owner can run
(plugin install from the marketplace, hook registration in a real session, a real GitHub or
Azure DevOps organisation). Section C names every behaviour that is verified against the
bundled `gh` and `az` mocks only. Nothing in this file claims a live platform result.

## A. Checks run in this build

| Check | Command | Result |
| --- | --- | --- |
| Plugin evals (27 bash cases, no LLM) | `bash plugins/ai-sdlc/evals/run.sh` | see the line `evals: 27 case(s), 0 failed` in the session report; runtime about 15 minutes on Windows because every jq call is a process |
| Adapter conformance under mocks | `bash plugins/ai-sdlc/scripts/platform/conformance.sh --platform all` | `conformance: 115 check(s), 0 failed`, identical stdout key sets |
| Python unit tests for `report.py` | `python -B -m unittest discover -s plugins/ai-sdlc/evals/python -v` | `Ran 18 tests ... OK` |
| Manifest validation | `claude plugin validate . --strict` and `claude plugin validate plugins/ai-sdlc --strict` | `Validation passed`, twice |
| Bash syntax | `bash -n` over `hooks/*.sh`, `scripts/*.sh`, `scripts/*/*.sh`, `scripts/platform/*/*.sh`, `bin/sdlc-platform`, `evals/cases/*.sh` | no errors |
| Rendered CI YAML parses | `render.sh <template> --config templates/examples/sdlc.config.json --out <f>` then `python -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' <f>` for all 4 GitHub workflows and 3 Azure pipelines | `yaml ok` for all 7 |
| No compiled artifacts tracked | `git ls-files \| grep -E '__pycache__\|\.py[cod]$'` | nothing (the tracked `report.cpython-310.pyc` was removed; `.gitignore` ignores `__pycache__/` and `*.py[cod]`) |

Not run in this build, stated plainly:

- `shellcheck -S warning ...` is not installed on the build machine and could not be installed from inside the session. `bash -n` is the substitute that was run. The repository CI (`.github/workflows/ci.yml`) and the rendered `sdlc-evals` templates run shellcheck on ubuntu; treat any `SC` finding there as a defect to fix.
- `actionlint` is not installed locally. The repository CI downloads it and runs it over `.github/workflows/ci.yml` and the rendered GitHub workflow templates.
- No live `gh` or `az` call, no real deployment, no real issue, no branch protection change was made.

## B. Steps only the repository owner can run

### B1. Install from the marketplace

```
/plugin marketplace add C:\Projects\ai-sdlc
/plugin install ai-sdlc@ai-sdlc-kit
claude plugin list
```

Expected: `ai-sdlc@ai-sdlc-kit` enabled, version `0.1.0`. Quick alternative: `claude --plugin-dir C:\Projects\ai-sdlc\plugins\ai-sdlc`.

### B2. Components registered

```
claude plugin details ai-sdlc@ai-sdlc-kit
```

Expected, each namespaced `ai-sdlc:`: commands `sdlc-init`, `sdlc-status`, `sdlc-upgrade`, `sdlc-start`, `sdlc-publish`, `sdlc-verify`, `sdlc-ship`, `sdlc-postmortem`, `sdlc-metrics-baseline`, `sdlc-metrics-report`; skills `sdlc-loop`, `sdlc-platform`, `sdlc-publish`, `sdlc-ship`, `sdlc-postmortem`, `sdlc-metrics`, `sdlc-security-review`; agents `sdlc-verifier`, `sdlc-security-auditor`, `sdlc-metrics-analyst`; hooks: `PreToolUse` in 3 matcher groups (6 scripts: `guard-secrets`, `guard-protected-paths`, `guard-verifier-readonly`, `guard-test-edits`, `guard-ticket-gate`, `gate-production`), `PostToolUse` in 1 group (`post-edit-verify`).

### B3. Hooks fire with `${CLAUDE_PLUGIN_ROOT}` resolved

Create a throwaway sdlc project and run one session with a debug file:

```bash
mkdir -p C:\Projects\ai-sdlc\.dev\scratch\gh && cd C:\Projects\ai-sdlc\.dev\scratch\gh && git init -q
bash C:\Projects\ai-sdlc\plugins\ai-sdlc\scripts\init\run.sh --platform none --tier 1 --team solo --verify "true" --yes
claude --debug-file .sdlc-debug.txt -p "Append the line 'verify' to NOTES.md and stop."
grep -E 'guard-secrets|guard-protected-paths|guard-verifier-readonly|guard-test-edits|guard-ticket-gate|gate-production|post-edit-verify' .sdlc-debug.txt | head -20
grep -c 'CLAUDE_PLUGIN_ROOT}' .sdlc-debug.txt
```

Expected: hook lines for all seven scripts under the plugin cache path; the second grep prints `0`; no `hook error`. Delete `.sdlc-debug.txt` afterwards.

### B4. Silence and speed in an unrelated repository

In a repository without `sdlc.config.json`:

```bash
claude --debug-file .sdlc-debug.txt -p "Append the line 'verify' to NOTES.md, then delete that line again, and stop."
grep -E 'hook error|BLOCKED|sdlc' .sdlc-debug.txt | grep -v 'ai-sdlc-kit\\ai-sdlc\\' | head
```

Expected: nothing. `evals/cases/hooks-silent.sh` measures the silent path at under 80 ms over bash startup on the build machine.

### B5. The shell guards and the verifier in a real session

In a tier 2 sdlc project without `.sdlc/ACTIVE_TICKET`, ask the agent to run `sed -i s/a/b/ src/<file>` and `bash scripts/<any>.sh`: both must be denied with `ai-sdlc guardrail: no active ticket`. Ask it to run `cat src/<file>` and the configured verify command: both must run. Then `/ai-sdlc:sdlc-verify`: the verifier must call `bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify/run-isolated.sh"` (visible in the transcript) and every direct test-runner attempt must be denied with a message naming the helper. Afterwards `git status --porcelain` in the project is empty and `git worktree list` shows one entry.

### B6. Release gates on a real project

```bash
bash <plugin-root>/scripts/loop/validate-report.sh .sdlc/verify/<report>.md
bash <plugin-root>/scripts/loop/validate-report.sh .sdlc/verify/<report>-security.md --security
bash <plugin-root>/scripts/ship/preflight.sh --pr <id>
```

Expected: exit 0 for a report the verifier just wrote for `HEAD`; after one more commit the first command exits 1 with a reason containing `HEAD`. `preflight.sh` prints `ready: true` only after `scripts/ship/authorize.sh` has been run from a terminal outside Claude Code.

## C. Mock-only behaviour (never ran against a real service)

Everything below passed `evals/run.sh` and `conformance.sh` against `scripts/platform/_mocks/bin/{gh,az}`, or was read from upstream documentation. Each item names the command that proves it on a real project. Run the Azure items in a checkout whose `origin` is an Azure Repos remote, `sdlc.config.json` says `"platform":"azure"`, and `az login` plus `az devops configure --defaults organization=... project=...` are done; run the GitHub items with a GitHub remote and `gh auth status` passing.

### C1. Azure relation type names

`work_item_link.sh` uses `--relation-type Successor` for `blocks`, `Parent` for `parent`, `Related` for `related`.

```bash
sdlc-platform work_item_create "verify A" /dev/null; sdlc-platform work_item_create "verify B" /dev/null
sdlc-platform work_item_link <idA> <idB> --type blocks
az boards work-item relation show --id <idB> -o json | jq '.relations[].rel'
```

Expected: `System.LinkTypes.Dependency-Reverse` on B and `Dependency-Forward` on A; the link call repeated exits 0 (idempotent).

### C2. Azure branch policy create and update flags

`branch_protect_apply.sh` runs `az repos policy list --branch --repository-id`, then `approver-count|required-reviewer|work-item-linking|comment-required|build create ...` and, on drift, the matching `... update --id <id> ...`. The comparison of managed settings (`minimumApproverCount`, `creatorVoteCounts`, `allowDownvotes`, `resetOnSourcePush`, `requiredReviewerIds`, `message`, `buildDefinitionId`, `displayName`, `queueOnSourceUpdateOnly`, `manualQueueOnly`, `validDuration`, `isEnabled`, `isBlocking`, scope) uses the JSON field names of the mock, which follow the REST policy configuration shape; a real `az repos policy list` may nest them differently.

```bash
sdlc-platform --dry-run branch_protect_apply main
sdlc-platform branch_protect_apply main
sdlc-platform branch_protect_apply main
jq '.review.requiredApprovals=2' sdlc.config.json > c && mv c sdlc.config.json
sdlc-platform branch_protect_apply main
az repos policy list --branch main -o table
```

Expected: first run `applied` non-empty; second run `applied` and `updated` empty; third run `updated` contains `approver-count` and the table shows a minimum of 2 reviewers; every other policy in the table is untouched. Any `unrecognized arguments` from `az`, or a policy that is re-created instead of updated, is a finding. `azure.requiredReviewers` entries are passed to `--required-reviewer-ids` as written (emails in the example config); the CLI may require identity ids, which is a finding to report with the exact error text.

### C3. Azure votes and `pr_get` approval

`pr_get.sh` reads `reviewers[].vote`, `isRequired`, `isContainer`, `uniqueName`, `displayName`, `id` and `createdBy` from `az repos pr show`.

```bash
sdlc-platform pr_get <pr-id>
az repos pr show --id <pr-id> -o json | jq '[.reviewers[] | {uniqueName, vote, isRequired, isContainer}]'
```

Expected: `review_decision` is `approved` only when the votes satisfy `review.requiredApprovals` (author excluded), every `azure.requiredReviewers` entry and every `isRequired` reviewer voted 5 or 10, and nobody voted below 0; `-5` or `-10` gives `changes_requested`; otherwise `pending`.

### C4. Azure policy evaluations as checks

`pr_checks.sh` reads `az repos pr policy list --id <pr>`; a check is named `<type displayName> (<settings displayName>)`, and the required check is the build policy whose display name is `azure.pipelineName`.

```bash
sdlc-platform pr_checks <pr-id>; echo "exit $?"
```

Expected: exit 0 with `reason: null` only when the review pipeline's build policy shows `approved`; exit 8 while it is `queued` or `running`; exit 1 with a `reason` when it is missing, `rejected`, `notApplicable`, or when the list is empty.

### C5. `az rest` thread POST for PR comments

```bash
printf 'verify comment\n' > .dev/scratch/c.md
sdlc-platform pr_comment <pr-id> .dev/scratch/c.md
```

Expected: `{"id":"<pr-id>","comment_id":"<number>","platform":"azure"}` and the comment visible on the PR.

### C6. `az pipelines create --skip-first-run true`

```bash
sdlc-platform ci_workflow_install
git add .azuredevops && git commit -m "ci: sdlc pipelines" && git push
sdlc-platform ci_workflow_install
az pipelines list -o table
```

Expected: first call installs three files; second call reports them `unchanged` and `registered` lists `sdlc-pr-review`, `sdlc-deploy`, `sdlc-evals`.

### C7. Azure pipeline review failure

Open a PR on a tier 3 Azure project with `ANTHROPIC_API_KEY` deliberately missing from the `sdlc-secrets` variable group.

Expected: the `sdlc-pr-review` run fails at the step `Review with Claude Code`, the PR comment begins `# ai-sdlc review FAILED (no review result)`, the `sdlc-cost-<id>` artifact exists with `review_status: failed`, and a build policy on the pipeline stays unsatisfied. Then restore the key and push: the run passes and the comment is a review with exactly one `Blocking: <n>` line.

### C8. GitHub issue dependencies and sub-issues APIs

```bash
sdlc-platform work_item_create "verify A" /dev/null; sdlc-platform work_item_create "verify B" /dev/null
sdlc-platform work_item_link <idA> <idB> --type blocks
gh api repos/<owner>/<repo>/issues/<idB>/dependencies/blocked_by --jq '.[].number'
```

Expected: `"native":true` and `<idA>`; `"native":false` with a `Blocked by: #<idA>` body line is the documented fallback where the API is unavailable.

### C9. GitHub `pr_checks` with no checks

On a branch with no workflows: `sdlc-platform pr_checks <pr-id>` must exit 1 with `reason` containing `no checks reported` (the mock returns `[]`; a real `gh pr checks` prints `no checks reported` on stderr and exits 1, which the adapter maps to the same result).

### C10. `claude-code-action` inputs and the result check

```bash
curl -s https://raw.githubusercontent.com/anthropics/claude-code-action/v1/action.yml | grep -E '^  (plugins|plugin_marketplaces|claude_args|use_sticky_comment|track_progress|anthropic_api_key|github_token):'
```

Expected: seven lines. On a tier 3 GitHub project, a PR review run posts one sticky comment; a run whose execution file ends with `subtype` other than `success` fails at the step `Fail when the review did not complete`.

### C11. Metrics export against a real organisation

```bash
sdlc-platform metrics_export 2026-06-01 2026-09-01 .dev/scratch/m.json; echo "exit $?"
jq '.sources, .warnings' .dev/scratch/m.json
```

Expected: exit 0 with `sources` all `configured` (Azure: `deployments` is `not-configured` until `azure.deployPipelineName` names a registered pipeline). Log out (`gh auth logout` or unset the PAT) and repeat: exit 1, no output file, the message names the failing command without printing a token or an `Authorization` header.

### C12. shellcheck and actionlint

```bash
cd C:\Projects\ai-sdlc\plugins\ai-sdlc
shellcheck -S warning hooks/*.sh scripts/*.sh scripts/*/*.sh scripts/platform/*/*.sh bin/sdlc-platform
```

Expected: no output and exit 0. The repository CI runs both tools; a red `ci` job on the first push after this build is the expected way to learn about a finding neither tool could produce locally.
