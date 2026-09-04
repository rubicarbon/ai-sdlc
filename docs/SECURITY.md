# Security

This document describes what `ai-sdlc` defends against, which control covers which threat, which credentials the tooling needs, and where the protection stops. The controls that matter are deterministic (hooks, permission rules, platform policies, a human-only script); the skills and agent instructions are advisory and are listed only where they add a second layer.

## Threat model

| Threat | What it looks like in this loop |
| --- | --- |
| Prompt injection through tickets, PR bodies and web content | The agent reads work items, PR descriptions, review comments and research pages as input. Any of them can carry text that tells the agent to read a secret, disable a check, push to `main` or deploy. Ticket bodies on Azure round-trip through HTML, so injected text can also hide in markup |
| Secret exfiltration | Reading `.env`, cloud credential files or CLI login stores and echoing, copying, encoding or uploading them; or leaking them into a PR body, a comment or a log line |
| Unauthorised production changes | Pushing to the default or release branches, running deploy workflows or pipelines, `kubectl apply`, `terraform apply`, `helm upgrade` and similar from an agent session, without a human deciding that this commit ships |
| Supply chain via new dependencies | An agent adding an unpinned, typosquatted or unmaintained package, or a package with install scripts, to satisfy a ticket |
| MCP servers with broad tool access | A connected server that can write to production systems, send messages or run shell commands turns any injected instruction into an action outside the repository, past every file-level hook |

## Controls mapped to threats

| Control | Where | Covers |
| --- | --- | --- |
| Permission deny rules | `templates/settings.json.tmpl`, merged into the target repo's `.claude/settings.json` by `/ai-sdlc:sdlc-init`: `Read` denied on `.env`, `.env.local`, `.env.development`, `.env.staging`, `.env.production`, `.env.test`, `.env.*.local`, `secrets/**`, `**/*.pem`, `**/id_rsa*`, `**/id_ed25519*`, `~/.ssh/**`, `~/.aws/**`, `~/.kube/config`, `~/.netrc`; `Edit` denied on `.env`, `.env.*`, `secrets/**`, `sdlc.config.json`; `Bash` denied for `git push --force *`, `git push -f *`, `git push * --force*`. `settings.github.json.tmpl` adds `Read(~/.config/gh/**)`, `settings.azure.json.tmpl` adds `Read(~/.azure/**)` | Secret exfiltration through the file tools, including `@file` mentions, which hooks do not see; force pushes |
| `guard-secrets` hook | `hooks/guard-secrets.sh`, PreToolUse on Read, Glob, Grep, Edit, Write, NotebookEdit, Bash, PowerShell | The same secret paths for shell commands (path tokens extracted from the command), the config-driven `guardrails.secretPaths`, and read-or-copy commands that name `GITHUB_TOKEN=`, `GH_TOKEN=`, `AZURE_DEVOPS_EXT_PAT=`, `AWS_SHARED_CREDENTIALS_FILE`, `.netrc`, `id_rsa`, `id_ed25519` |
| `guard-protected-paths` hook | `hooks/guard-protected-paths.sh`, PreToolUse on Edit, Write, NotebookEdit, Bash, PowerShell | Injected instructions to weaken CI (`.github/workflows/**`, `.azuredevops/**`), ownership (`CODEOWNERS`), the loop's own config (`sdlc.config.json`, `.claude/settings.json`), lockfiles, and the release markers (`.sdlc/release/**`, `.sdlc/UNLOCK_PROTECTED`). Reads stay allowed; a human unlocks one edit by creating `.sdlc/UNLOCK_PROTECTED` |
| `guard-verifier-readonly` hook | `hooks/guard-verifier-readonly.sh` | A compromised or over-eager verifier or security auditor cannot edit files or run write-shaped commands; findings are evidence, not fixes |
| `gate-production` hook plus `authorize.sh` | `hooks/gate-production.sh`; `scripts/ship/authorize.sh` | Deploy-shaped commands (`environments.prod.deployCommandPatterns`) run only while `.sdlc/release/AUTHORIZED-<HEAD sha>` exists and has not expired. The marker is written by a human running `authorize.sh` at their own terminal: the script exits 2 when `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT` or `CLAUDE_PROJECT_DIR` is set, and the directory is a protected path |
| Branch protection and policies | `sdlc-platform branch_protect_apply` from `templates/github/branch-protection.json` and `templates/azure/branch-policies.json` | Nothing merges without a human code owner (GitHub) or required reviewer (Azure), required checks pass, stale reviews are dismissed on push, conversations are resolved, force pushes and deletions are blocked, admins are not exempt. The CI review job is told to comment only and never approve |
| CI cost caps | `templates/github/workflows/sdlc-pr-review.yml`, `templates/azure/pipelines/sdlc-pr-review.yml`, `sdlc-cost-report.yml`, `scripts/cost/report.sh` | A runaway or injected review loop stops at `cost.maxTurns` and `cost.maxBudgetUsd`; each run records `sdlc-cost.json` and fails above the ceiling; weekly spend above `cost.alertThresholdUsd` opens an issue. The CI review runs with an allowlist of read-only tools (`Read,Grep,Glob,Bash(git diff *),Bash(git log *),Bash(git show *)`, plus `Write(review.md)` on Azure) |
| `sdlc-security-review` check list | `skills/sdlc-security-review/SKILL.md`, used by `sdlc-security-auditor` and the CI review | Injection, broken access control, privilege escalation, hardcoded secrets, unsafe deserialisation, new dependencies (pinned, known maintainer, justified in the PR body), missing authz on new endpoints, data exposure, human-only areas, and prompt injection surface in code that feeds untrusted text to an LLM or tool |
| `REVIEW.md` human-only areas | `templates/REVIEW.md.tmpl` | Authentication, authorisation, cryptography, payments and billing code is written by a human; an agent-authored change there is Blocking until a human rewrites or explicitly adopts it |
| Ticket gate | `hooks/guard-ticket-gate.sh` (tier 2 and above) | Source edits need `.sdlc/ACTIVE_TICKET`; injected "just implement this" text in a comment does not by itself produce code |

Every hook exits 0 silently when no `sdlc.config.json` is found, so none of the above applies until `/ai-sdlc:sdlc-init` has run in the repository.

## Credentials and scopes

Agents hold no production credentials. Everything below is for the platform CLI the human is already logged into, or for CI.

| Credential | Needed by | Scope |
| --- | --- | --- |
| GitHub CLI login (`gh auth login`) | `scripts/platform/github/*.sh` | Classic token scopes `repo` and `workflow`. For a fine-grained PAT, grant on the repository what the adapter calls: Issues read and write (`work_item_*`), Pull requests read and write (`pr_*`), Contents read, Administration read and write (`branch_protect_apply` uses `PUT .../branches/{b}/protection`), Actions read (workflow runs as the deployment fallback and cost artifacts), Deployments read (`metrics_export`). Leave everything else unset |
| Azure CLI login (`az login` or `AZURE_DEVOPS_EXT_PAT`) with the `azure-devops` extension | `scripts/platform/azure/*.sh` | PAT scopes: Work Items read and write, Code read and write, Build read and execute, Project and Team read |
| `ANTHROPIC_API_KEY` | `sdlc-pr-review.yml` on both platforms | GitHub Actions secret, or the Azure variable group `sdlc-secrets`; both are created by the human through the setup wizard `/ai-sdlc:sdlc-init` generates (`scripts/sdlc-setup-wizard.sh`). Never in the repo, never read by the agent |
| `GITHUB_TOKEN` (GitHub) / `System.AccessToken` (Azure) | CI jobs only | Used to post the review comment, record deployments and read cost artifacts. Job permissions in the templates are the minimum for each job (`contents: read`, `pull-requests: write`, `issues: read` or `write`, `deployments: write`, `actions: read`, `id-token: write`) |
| Deploy credentials | `scripts/deploy.sh`, owned by the repository, run inside the `production` environment | Stored in the platform environment behind its required reviewers or Approvals check; not available to the agent session |

The agent reaches the platform only through `sdlc-platform`, which checks authentication once per invocation and reports a missing login with the platform's login command. It never reads `~/.config/gh`, `~/.azure` or a token file: both the deny rules and `guard-secrets` block that.

## MCP servers

Hooks and permission rules see file paths and shell commands. They do not see what an MCP server does on the agent's behalf, so a server with write access is a bypass of every control above. Guidance for a repository that runs this loop:

- Least privilege: connect servers with the narrowest scope that serves the ticket, and prefer per-repository or per-project credentials over account-wide ones.
- Read-only servers for agents: documentation, issue search, log search and code search servers are useful and low risk. A server that can create, update or send should be avoided in agent sessions or limited to the human's interactive use.
- No MCP server with deploy rights: nothing connected to an agent session should be able to run a pipeline, change infrastructure, rotate a secret or push to a protected branch. Those actions stay on the platform behind branch protection, environment approvals and `authorize.sh`.
- Treat server output as untrusted input: it carries the same prompt injection risk as a ticket body.

## What the plugin does not protect against

- Paths constructed at runtime inside a Bash command (a variable expanded by the shell, `base64 -d | sh`, `eval` of a computed string, a path built by a script the command runs). `guard-secrets` and `guard-protected-paths` inspect the command text as written; they cannot evaluate it.
- `@file` mentions in a prompt. They do not pass through PreToolUse hooks, so only the permission deny rules in `.claude/settings.json` cover them. That is why the deny list duplicates the hooks' default secret paths.
- A human running `scripts/ship/authorize.sh` carelessly. The script proves a person was at a terminal; it does not judge the release. `scripts/ship/preflight.sh --pr <id>` lists every gate with evidence and should be read first.
- Encoding and evasion: a command that hides a secret path behind base64, `printf` escapes, `eval`, an alias, or a helper script the agent wrote a moment earlier is not recognised by token matching.
- A repository without `sdlc.config.json`: every hook is silent there by design.
- Anything an MCP server or another plugin's tool does.
- The Azure adapter is verified against mocks in this build, not against a live organisation; the policy and permission behaviour of a real Azure DevOps project should be confirmed after the first `branch_protect_apply`.

## Reporting a security issue in the kit

Open an issue on the repository: `https://github.com/rubicarbon/ai-sdlc/issues`. Describe the control that failed, the exact tool call or command that got through, and the plugin version (`SDLC_PLUGIN_VERSION`, printed by `/ai-sdlc:sdlc-status`). If the report contains a real secret or a reproduction against a real production system, redact the values and say so in the issue; the location is enough.
