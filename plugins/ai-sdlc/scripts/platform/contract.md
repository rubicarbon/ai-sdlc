# Platform adapter contract

This is the normative interface between `ai-sdlc` and a code-hosting platform. Skills, commands, agents, CI templates and the Azure `docs/agents/issue-tracker.md` call **only** this contract, through the dispatcher `bin/sdlc-platform`, and never `gh`, `az` or `glab` directly. Adding a platform means adding one directory `scripts/platform/<platform>/` with one script per function and making `conformance.sh` pass; nothing else changes.

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
| 1 | operation failed | one line starting with `ai-sdlc:` explaining what failed, followed by the CLI's own error text |
| 2 | usage error (bad arguments) | one line starting with `ai-sdlc:` |
| 3 | not supported on this platform | exactly `ai-sdlc: not supported on this platform: <platform> <reason>` |
| 8 | pending (only `pr_checks`) | empty |

There are no silent no-ops. A function that cannot do its job on a platform says so with exit 3.

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

### `pr_comment <id> <body-file>`
```json
{"id":"77","comment_id":"1001","platform":"azure"}
```

### `pr_checks <id>`
```json
{"id":"77","status":"pass","checks":[{"name":"ci","status":"pass","url":"..."}],"platform":"github"}
```
`status` and each check's `status`: `pass`, `fail`, `pending`, `skipped`. Exit 0 when overall `pass`, 1 when `fail`, 8 when `pending`. On Azure the checks are the branch policy evaluations of the PR (approver count, build, required reviewers, work-item linking, comment resolution).

### `branch_protect_apply <branch>`
Idempotent: applies the protection described in `templates/github/branch-protection.json` or `templates/azure/branch-policies.json`, rendered with the project's config (required checks, reviewers, approval count). Running it twice reports everything under `unchanged`.
```json
{"branch":"main","applied":["approver-count"],"unchanged":["build","comment-required"],"platform":"azure"}
```
- GitHub: `PUT /repos/{o}/{r}/branches/{b}/protection` (replace semantics) with code-owner reviews required.
- Azure: `az repos policy list` then create or update `approver-count`, `required-reviewer` (config `azure.requiredReviewers`; there is no CODEOWNERS on Azure Repos), `build` (when a pipeline id is known), `work-item-linking`, `comment-required`.

### `ci_workflow_install`
Copies the rendered CI files into the repo and registers them where the platform needs registration. Idempotent: unchanged files are reported as `unchanged`; changed files are written only with `--force`, otherwise reported under `pending` with a diff on stderr.
```json
{"installed":[".github/workflows/sdlc-pr-review.yml"],"unchanged":[],"pending":[],"registered":[],"platform":"github"}
```
- Azure additionally registers each pipeline with `az pipelines create --skip-first-run` unless a pipeline with that name exists (`registered`).

### `metrics_export <since> <until> <out.json>`
Writes the normalised metrics file (schema below) and prints counts.
```json
{"prs":42,"deployments":17,"incidents":3,"reverts":1,"out":".sdlc/metrics/raw-2026-09.json","platform":"github"}
```
Normalised file:
```json
{
  "platform":"github","repo":"owner/name","since":"2026-08-01","until":"2026-09-01","exported_at":"...",
  "prs":[{"id":"77","created_at":"...","merged_at":"...","first_review_at":"...","additions":120,"deletions":8,"changed_files":4,"first_commit_at":"...","author":"login","is_revert":false}],
  "deployments":[{"id":"...","environment":"production","started_at":"...","finished_at":"...","status":"success","sha":"..."}],
  "incidents":[{"id":"...","opened_at":"...","closed_at":"...","labels":["incident"]}],
  "reverts":[{"sha":"...","committed_at":"...","reverts_sha":"..."}]
}
```
Sources: GitHub uses merged PRs with reviews, the Deployments API (fallback: workflow runs of the configured deploy workflow), issues labelled per `metrics.incidentLabel`, and `git log --grep '^Revert'`. Azure uses completed PRs, PR threads for the first vote, runs of the configured deploy pipeline, a WIQL query for bugs, and the same git log. Dates are ISO 8601 UTC.

## Common behaviour

- `--dry-run` (or `SDLC_DRY_RUN=1`) prints the platform CLI command(s) that would run, one per line, to stdout and exits 0 without calling the platform.
- `--mock` (or `SDLC_PLATFORM_MOCK=1`) prepends `scripts/platform/_mocks/bin` to `PATH`, where fake `gh` and `az` answer from `scripts/platform/_mocks/responses/` and log every invocation to `$SDLC_MOCK_LOG`. `conformance.sh` runs both adapters this way and diffs the normalised outputs.
- Authentication is checked once per invocation (`gh auth status`; `az account show` and `az devops configure -l`), and a missing login is exit 1 with the platform's login command in the message.
- Bodies are always passed as files, never inline, so Markdown with quotes and newlines survives.
- Every adapter script sources `scripts/_root.sh`, `scripts/_lib.sh` and `scripts/platform/_common.sh`, in that order.

## Conformance

`scripts/platform/conformance.sh [--platform github|azure|all]` runs the same assertion list against each adapter under mocks: exit codes, stdout shapes (required keys, types), idempotency of `work_item_link` and `branch_protect_apply`, the exact form of "not supported" messages, and a static check that no Azure script mentions `gh` and no GitHub script mentions `az`. It exits non-zero on the first divergence between platforms.
