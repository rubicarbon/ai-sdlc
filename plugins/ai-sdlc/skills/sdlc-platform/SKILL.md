---
name: sdlc-platform
description: "How to talk to GitHub or Azure DevOps from this project. Use whenever work items, issues, pull requests, checks, branch protection, CI registration or metrics data are needed. Always through the sdlc-platform contract, never gh or az directly."
---

# Platform adapter

`sdlc-platform` is on your PATH while this plugin is enabled. It resolves the platform from `sdlc.config.json` (or the git remote) and runs the matching adapter. Call it for every platform operation; the adapter owns the CLI details, the authentication check and the output shape, so the same call works on GitHub and Azure DevOps.

```
sdlc-platform <function> [args...]            # normal
sdlc-platform --dry-run <function> [args...]  # print the CLI commands that would run, change nothing
sdlc-platform --platform azure <function> ... # override detection (config "both")
```

## Functions

| Call | Result (one JSON line) |
| --- | --- |
| `platform_detect` | `github` or `azure` (plain text) |
| `work_item_create <title> <body.md> [--labels a,b] [--type T] [--parent ID]` | `{"id","url"}` |
| `work_item_get <id>` | `{"id","title","body","state":"open|closed","labels":[],"url","created_at","closed_at","assignees":[]}` |
| `work_item_link <from> <to> --type blocks|parent|related` | `{"from","to","type","native"}`; `blocks` = from must finish before to starts |
| `work_item_comment <id> <body.md>` | `{"id","comment_id"}` |
| `pr_create <title> <body.md> <base> <head> [--draft]` | `{"id","url"}` |
| `pr_get <id>` | `{"id","title","state":"open|merged|closed","base","head","url","created_at","merged_at","additions","deletions","changed_files","review_decision","author"}` |
| `pr_comment <id> <body.md>` | `{"id","comment_id"}` |
| `pr_checks <id>` | `{"id","status":"pass|fail|pending","checks":[...],"required":[...],"reason":null|"..."}`; exit 0 only when at least one check passed, none failed or is pending, and every required check (GitHub `github.requiredChecks`, Azure the `azure.pipelineName` build policy) passed; exit 8 while a check is pending; exit 1 on a failure, an empty check list, a missing or skipped required check, or a skipped-only list (`reason` says which) |
| `branch_protect_apply <branch>` | `{"branch","applied":[],"updated":[],"unchanged":[],"skipped":[]}` (idempotent; `updated` lists policies whose managed settings drifted and were reconciled) |
| `ci_workflow_install [--force]` | `{"installed":[],"unchanged":[],"pending":[],"registered":[]}` (idempotent) |
| `metrics_export <since> <until> <out.json>` | counts plus `warnings`, and the normalised file at `out.json` (with `sources` and `warnings`); a CLI or API failure is exit 1 with the failing command named, never an empty export |

Bodies are always files: write the Markdown to a file first (for example under `.sdlc/tmp/`), pass the path, delete it afterwards. Quotes and newlines survive that way.

## Exit codes

`0` done. `1` the platform refused; stderr starts with `ai-sdlc:` and quotes the CLI error (missing login shows the login command to run). `2` wrong arguments. `3` not supported on this platform, with the reason. `8` checks still pending.

Read stdout as JSON (`jq -r .id`). Read stderr as the explanation. When a call exits 3, report the limitation to the user instead of reaching for `gh` or `az` yourself: the contract is the only supported route, and the Azure adapter is what makes their flow work.

## Azure specifics worth knowing

Work items are created with the process template's story type (`azure.workItemType` overrides). `blocks` becomes a Successor link, `parent` a Parent link. PR size fields are `null` in `pr_get`. Branch protection is a set of branch policies; a required-reviewer policy needs `azure.requiredReviewers` in the config because Azure Repos has no CODEOWNERS.
