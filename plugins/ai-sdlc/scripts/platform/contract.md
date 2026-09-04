# Platform adapter contract

This is the normative interface between `ai-sdlc` and a code-hosting platform. Skills, commands, agents, CI templates and the Azure `docs/agents/issue-tracker.md` call **only** this contract, through the dispatcher `bin/sdlc-platform`, and never `gh`, `az` or `glab` directly. Adding a platform means adding one directory `scripts/platform/<platform>/` with one script per function (eleven; `platform_detect` is shared in `scripts/platform/_detect.sh` and needs one new remote-URL pattern there), then making `conformance.sh` pass. The dispatcher accepts any platform that has a directory, so nothing else changes.

## Invocation

```
sdlc-platform [--platform github|azure] [--dry-run] [--mock] <function> [args...]
sdlc-platform --list | --detect | --help
```

`bin/` is on the Bash tool's `PATH` while the plugin is enabled, so `sdlc-platform` is a bare command inside Claude Code. Outside Claude Code call `<plugin-root>/bin/sdlc-platform`.

Platform resolution order: `--platform`, `$SDLC_PLATFORM`, `platform` in `sdlc.config.json` (`both`/`auto` defer to detection), then `platform_detect`. `none` exits 3 for every function except `platform_detect`.

## Exit codes

| Code | Meaning | stderr |
| --- | --- | --- |
| 0 | success | empty (informational lines allowed with `SDLC_VERBOSE=1`) |
| 1 | operation failed; for `pr_checks` also: checks failed, or the required checks are unsatisfied or not configured | one line starting with `ai-sdlc:` explaining what failed, followed by the CLI's own error text (`pr_checks` puts the verdict's `reason` in the JSON instead) |
| 2 | usage error (bad arguments) | one line starting with `ai-sdlc:` |
| 3 | not supported on this platform | exactly `ai-sdlc: not supported on this platform: <platform> <reason>` |
| 8 | pending (only `pr_checks`): at least one check is still running and none has failed | empty |

There are no silent no-ops. A function that cannot do its job on a platform says so with exit 3.

A platform CLI call that exits non-zero, or prints something that is not JSON, ends the function with exit 1 and the message `ai-sdlc: <cli command without secrets> failed (exit N): <first stderr line>` or `ai-sdlc: <command> returned invalid JSON`. A failure is never turned into an empty result (no "zero PRs", no "no policies", no "not protected"), because an empty answer would let a gate pass or make an idempotent function create duplicates.

## Functions and stdout shapes

Every function prints **one JSON object on one line** to stdout (unless stated otherwise). Field names and types are identical across platforms; a platform that cannot supply a field prints `null` for it, never omits it. IDs are strings.

### `platform_detect`
Prints `github` or `azure` (plain text, no JSON). Exit 3 when the remote is neither or absent. Reads `git remote get-url origin` (override the remote name with `SDLC_GIT_REMOTE`).

### `work_item_create <title> <body-file> [--labels a,b] [--type T] [--parent ID]`
Creates a work item whose description is the Markdown in `<body-file>`.
```json
{"id":"123","url":"https://.../123","platform":"github"}
```
- GitHub: `gh issue create --title --body-file --label ...`; `--type` is ignored (`null` in `type`); `--parent` adds the new issue as a sub-issue of the parent.
- Azure: `az boards work-item create --type <T> --title --description <html>`; `--labels` become `System.Tags`; `--type` defaults to the process template's story type (`azure.workItemType` in config overrides); `--parent` adds a `Parent` relation. Markdown is converted to HTML for the description and the raw Markdown is kept as the first comment.

### `work_item_get <id>`
```json
{"id":"123","title":"...","body":"...","state":"open","labels":["a","b"],"url":"...","created_at":"2026-01-02T03:04:05Z","closed_at":null,"assignees":["login"],"platform":"github"}
```
`state` is `open` or `closed` (Azure maps every non-terminal state to `open`; `Closed`, `Done`, `Removed`, `Resolved` map to `closed`). `body` is the Markdown source when available (GitHub) or the HTML description converted back to text (Azure).

### `work_item_link <from-id> <to-id> --type blocks|parent|related`
`blocks`: `<from>` must be finished before `<to>` can start. `parent`: `<from>` is the parent of `<to>`. Repeating a link is success (idempotent).
```json
{"from":"12","to":"13","type":"blocks","native":true,"platform":"azure"}
```
- GitHub: `blocks` uses the issue dependencies API (`POST /repos/{o}/{r}/issues/{to}/dependencies/blocked_by` with the blocker's database id). When the API returns 403/404 (feature unavailable), the adapter appends a `Blocked by: #<from>` line to `<to>`'s body and reports `"native":false`. `parent` uses the sub-issues API. `related` appends `Related: #<from>` (`native:false`).
- Azure: `az boards work-item relation add --id <from> --relation-type Successor --target-id <to>` for `blocks` (Dependency-Forward), `Parent`/`Child` for `parent`, `Related` for `related`. Always `native:true`.

### `work_item_comment <id> <body-file>`
```json
{"id":"123","comment_id":"456","platform":"github"}
```
`comment_id` may be `null` on Azure when the CLI does not return it.

### `pr_create <title> <body-file> <base> <head> [--draft]`
```json
{"id":"77","url":"https://.../pull/77","platform":"github"}
```
Azure URL is `<repository.webUrl>/pullrequest/<id>`.

### `pr_get <id>`
```json
{"id":"77","title":"...","state":"open","base":"main","head":"feature/x","url":"...","created_at":"...","merged_at":null,"closed_at":null,"additions":120,"deletions":8,"changed_files":4,"review_decision":"pending","author":"login","platform":"github"}
```
`state`: `open`, `merged`, `closed`. `review_decision`: `approved`, `changes_requested`, `pending`. Azure prints `null` for `additions`, `deletions`, `changed_files` (the CLI does not expose them; `metrics_export` computes them from git when possible).

- GitHub: `review_decision` is GitHub's own `reviewDecision` (`APPROVED`, `CHANGES_REQUESTED`, else `pending`), which already applies the branch protection's approval count and code-owner rules.
- Azure: computed from the reviewer votes (10 approved, 5 approved with suggestions, 0 no vote, -5 waiting for author, -10 rejected). `changes_requested` when any reviewer voted below 0. `approved` only when all of the following hold: the number of approvals (vote >= 5) from reviewers who are neither the PR author (matched on `uniqueName` or `id`) nor a group (`isContainer`) is at least `review.requiredApprovals` (default 1, never less than 1); every entry of `azure.requiredReviewers` (matched case-insensitively against `uniqueName`, `displayName` or `id`) has voted >= 5; every reviewer flagged `isRequired` has voted >= 5. Otherwise `pending`. The author's own vote never counts towards any rule.

### `pr_comment <id> <body-file>`
```json
{"id":"77","comment_id":"1001","platform":"azure"}
```

### `pr_checks <id>`
```json
{"id":"77","status":"pass","checks":[{"name":"ci","status":"pass","url":"..."}],"required":["ci","lint"],"reason":null,"platform":"github"}
```
Each check's `status`: `pass`, `fail`, `pending`, `skipped`. Overall `status`: `pass`, `fail`, `pending`. `required` lists the check names the configuration demands; `reason` is `null` on `pass` and otherwise one sentence saying why not. Exit 0 when `pass`, 8 when `pending`, 1 when `fail`.

The verdict never passes with zero checks. The rules are evaluated in this order and are identical on every platform (they live in one shared function):

1. any check `fail` -> `fail`, reason `failing checks: <names>`;
2. else any check `pending` -> `pending`, reason `pending checks: <names>`;
3. else an empty check list -> `fail`, reason starting `no checks reported on the pull request` (checks not configured or not started yet: fail closed, re-run later);
4. else a required name that is absent from the list, or present only as `skipped` -> `fail`, reason `required checks missing or skipped: <names>`;
5. else no check has status `pass` (everything was skipped) -> `fail`, reason `every check was skipped`;
6. else `pass`.

A required name is satisfied by a check with exactly that name or by one named `<Type> (<name>)`, which is how Azure names a build policy evaluation (`Build (sdlc-pr-review)`).
- GitHub: checks are `gh pr checks --json name,state,link`; `required` is `github.requiredChecks` (`[]` when unset, so rule 4 never triggers and rule 5 carries the skipped-only case).
- Azure: checks are the branch policy evaluations of the PR (`az repos pr policy list`: approver count, build, required reviewers, work-item linking, comment resolution); `required` is `[azure.pipelineName]` (default `sdlc-pr-review`), the build policy that runs the CI review pipeline.

### `branch_protect_apply <branch>`
Idempotent: makes the protection described in `templates/github/branch-protection.json` or `templates/azure/branch-policies.json`, rendered with the project's config (required checks, reviewers, approval count), true for the branch. It compares the settings it manages with what the platform currently has: missing -> created (`applied`), present but different -> changed in place (`updated`), equal -> `unchanged`. Running it twice reports everything under `unchanged` with `applied` and `updated` empty. Changing the config (for example `review.requiredApprovals`) and re-running reports the affected policy under `updated`.
```json
{"branch":"main","applied":["approver-count"],"updated":[],"unchanged":["comment-required"],"skipped":["build: pipeline 'sdlc-pr-review' is not registered yet (run ci_workflow_install first)"],"platform":"azure"}
```
`skipped` lists policies that could not be applied yet and why (GitHub always prints `[]`).
- GitHub: `GET` then `PUT /repos/{o}/{r}/branches/{b}/protection` (replace semantics) with code-owner reviews required. The entries are the managed fields (`strict`, `contexts`, `enforce_admins`, `dismiss_stale_reviews`, `require_code_owner_reviews`, `required_approving_review_count`, `require_last_push_approval`, `allow_force_pushes`, `allow_deletions`, `required_conversation_resolution`, `required_linear_history`, `lock_branch`). A branch with no protection yet (HTTP 404) reports every field under `applied`; fields that differ on an existing protection go to `updated`. Any other failure to read the protection is exit 1, never treated as "not protected".
- Azure: `az repos policy list --branch <b> --repository-id <id>`, then per desired policy the existing policy of the same type (well-known type id, display name as fallback) whose scope is exactly `refs/heads/<branch>` (`matchKind` exact, `repositoryId` equal to this repository or null) is compared on the managed settings only: `approver-count` `minimumApproverCount`, `creatorVoteCounts`, `allowDownvotes`, `resetOnSourcePush`; `required-reviewer` `requiredReviewerIds` (as a case-insensitive set) and `message`; `build` `buildDefinitionId`, `displayName`, `queueOnSourceUpdateOnly`, `manualQueueOnly`, `validDuration`; every kind `isEnabled` and `isBlocking`. Missing -> `az repos policy <kind> create`, different -> `az repos policy <kind> update --id <id>` with the same flags, equal -> unchanged. Policies of other types, other branches or other repositories are never read for comparison nor written. The entries are the kinds: `approver-count`, `required-reviewer` (config `azure.requiredReviewers`; there is no CODEOWNERS on Azure Repos), `build` (skipped until the pipeline named `azure.pipelineName` is registered), `work-item-linking`, `comment-required`.

### `ci_workflow_install`
Copies the rendered CI files into the repo and registers them where the platform needs registration. Idempotent: unchanged files are reported as `unchanged`; changed files are written only with `--force`, otherwise reported under `pending` with a diff on stderr.
```json
{"installed":[".github/workflows/sdlc-pr-review.yml"],"unchanged":[],"pending":[],"registered":[],"platform":"github"}
```
- Azure additionally registers each pipeline with `az pipelines create --skip-first-run` unless a pipeline with that name exists (`registered`). A failing `az pipelines list` is exit 1, never "not found" (that would register the pipeline twice).
- Under `--dry-run` both adapters render to temp files, report `dry-run: would install <file>` / `would overwrite <file>` / `<file> unchanged` on stderr, print the registration commands and write nothing into the repository.

### `metrics_export <since> <until> <out.json>`
Writes the normalised metrics file (schema below) and prints counts plus the coverage warnings.
```json
{"prs":42,"deployments":17,"incidents":3,"reverts":1,"out":".sdlc/metrics/raw-2026-09.json","warnings":[],"platform":"github"}
```
Normalised file:
```json
{
  "platform":"github","repo":"owner/name","since":"2026-08-01","until":"2026-09-01","exported_at":"...",
  "sources":{"prs":"configured","deployments":"configured","incidents":"configured","reverts":"configured"},
  "warnings":[],
  "prs":[{"id":"77","created_at":"...","merged_at":"...","first_review_at":"...","additions":120,"deletions":8,"changed_files":4,"first_commit_at":"...","author":"login","is_revert":false}],
  "deployments":[{"id":"...","environment":"production","started_at":"...","finished_at":"...","status":"success","sha":"..."}],
  "incidents":[{"id":"...","opened_at":"...","closed_at":"...","labels":["incident"]}],
  "reverts":[{"sha":"...","committed_at":"...","reverts_sha":"..."}]
}
```
Sources: GitHub uses merged PRs with reviews, the Deployments API (or workflow runs of `github.deployWorkflow` when set), issues labelled per `metrics.incidentLabel`, and `git log --grep '^Revert'`. Azure uses completed PRs, PR threads for the first vote, runs of the configured deploy pipeline, a WIQL query for work items tagged with `metrics.incidentLabel`, and the same git log. Dates are ISO 8601 UTC.

`sources` says where each series came from so a reader can tell "zero" from "not measured": `prs` and `incidents` are always `configured`; `deployments` is `configured` on GitHub (the Deployments API always exists) and on Azure when `azure.deployPipelineId` is set or a pipeline named `azure.deployPipelineName` (default `sdlc-deploy`) exists, else `not-configured` with an empty series and a warning; `reverts` is `configured` when the local git history covers the period and `partial` when the clone is shallow (`git rev-parse --is-shallow-repository`), has no commit older than `<since>`, or `git log` fails, each with a warning. `warnings` is a list of strings; Azure adds `N of M pull requests have no local merge commits; size and first_commit_at are null for them` when the merge commits are not in the local clone. The stdout summary repeats the same `warnings`.

Every CLI call must succeed and return JSON (see the exit-code table); the file is assembled in a temporary location and moved to `<out.json>` only at the end, so a failure leaves no file behind, and `--dry-run` writes no file at all. The Azure `az rest` calls carry the PAT in a header that never appears in a log line or error message.

## Common behaviour

- `--dry-run` (or `SDLC_DRY_RUN=1`) prints the platform CLI command(s) that would run, one per line, to stdout and exits 0 without calling the platform, and never writes into the target repository: `ci_workflow_install` renders to temp files and reports on stderr, `metrics_export` writes no output file, `branch_protect_apply` and `work_item_create` only print the commands (`evals/cases/platform-dry-run.sh` hashes the repository tree before and after each call).
- `--mock` (or `SDLC_PLATFORM_MOCK=1`) prepends `scripts/platform/_mocks/bin` to `PATH`, where fake `gh` and `az` generate canned answers in code, keep ids, relations, branch protection and policy settings under `$SDLC_MOCK_STATE`, and log every invocation to `$SDLC_MOCK_LOG`. `conformance.sh` runs both adapters this way and diffs the normalised outputs. The mocks honour test knobs: `SDLC_MOCK_CHECKS=pass|fail|pending|empty|skipped` (what `pr_checks` sees), `SDLC_MOCK_PR_REVIEWERS=<json array>` (Azure `repos pr show` reviewers), and `SDLC_MOCK_FAIL`, `SDLC_MOCK_MALFORMED`, `SDLC_MOCK_EMPTY` set to a space-joined subcommand prefix such as `pr list` or `repos pr list` (that call fails with exit 1, prints `{not json`, or prints `[]` / `{"value":[]}`). The mock `az repos policy list` returns every stored policy regardless of `--branch`, so the adapter's own scope filter is what the tests exercise.
- Authentication is checked once per invocation (`gh auth status`; `az account show` and `az devops configure -l`), and a missing login is exit 1 with the platform's login command in the message.
- Bodies are always passed as files, never inline, so Markdown with quotes and newlines survives.
- Every adapter script sources `scripts/_root.sh`, `scripts/_lib.sh` and `scripts/platform/_common.sh`, in that order.

## Conformance

`scripts/platform/conformance.sh [--platform github|azure|all]` runs the same assertion list against each adapter under mocks: exit codes, stdout shapes (required keys, types), the five `pr_checks` verdicts (pass, fail, pending, empty, skipped-only) with their reasons and exit codes, idempotency of `work_item_link` and `branch_protect_apply` (`applied` and `updated` both empty on the second run), `metrics_export` sources and warnings plus the no-file-on-failure rule, the exact form of "not supported" messages, and a static check that no Azure script mentions `gh` and no GitHub script mentions `az`. It exits non-zero on the first divergence between platforms. The eval cases `pr-checks-policy`, `azure-approval`, `azure-policy-drift`, `metrics-export-errors` and `platform-dry-run` under `evals/cases/` cover the configuration-dependent behaviour (required checks, vote rules, policy drift, error handling, dry-run) in scratch repositories.
