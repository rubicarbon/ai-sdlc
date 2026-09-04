---
description: "Initialise or re-run ai-sdlc in the current repository: detect the platform and stack, interview, render the tier's files, and list the human-only platform steps. The only command that writes into the user's repo."
disable-model-invocation: true
argument-hint: "[--platform github|azure|both|none] [--tier 0-3] [--team solo|team] [--verify <cmd>] [--envs dev,staging,prod] [--deploy-staging <cmd> --deploy-production <cmd> | --no-deploy] [--azure-org <url> --azure-project <p> --azure-repo <r>] [--yes]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/init/detect.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/init/run.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/reuse/check-mattpocock.sh *), Bash(jq *)
---

Set up the SDLC loop in the repository at the working directory. Everything written goes through `scripts/init/run.sh`; you never write the files by hand.

## 1. Detect

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init/detect.sh" --repo-dir .
```

Read the JSON: `platform`, `repo.owner`/`repo.name`, `azure.*`, `cli.gh`/`cli.az` (present, authenticated, `devopsExtension`), `stack`, `verifyCandidates`, `deployCandidates` (filled only when `scripts/deploy.sh` exists), `mattpocock.installed`/`editable_copies`, `existing.config`. When `existing.config` is true, skip to step 3: run.sh is idempotent and reports the state.

## 2. Interview

Flags in `$ARGUMENTS` answer their question without asking. `--yes` (or `--non-interactive`) accepts every default. Otherwise ask with AskUserQuestion, one topic at a time, defaults first:

| Topic | Default | Flag |
| --- | --- | --- |
| Platform | detected `platform` | `--platform github|azure|both|none` |
| Repo identifiers | detected owner/name; for Azure confirm org url, project, repo (run.sh refuses Azure without all three) | `--owner --name`, `--azure-org --azure-project --azure-repo` |
| Inner loop | if `mattpocock.installed` is false, offer `/plugin install mattpocock-skills`; if `editable_copies` is non-empty, warn that both routes load every skill twice; for Azure say `docs/agents/issue-tracker.md` is ours and their setup should get the answer `Other` | none (informational) |
| Stack | detected `stack.language`/`packageManager` | none |
| Verification command | `verifyCandidates[0]`, offer the rest | `--verify "<cmd>"` (also `--format`, `--lint`) |
| Environments and gates | `dev,staging,prod`: dev gate none, staging auto, prod human with deploy patterns | `--envs` |
| Starting tier | 0; tiers render cumulatively, so 3 includes 0 to 2 | `--tier 0-3` |
| Deploy commands | none; ask only for tier 3 with a platform other than `none`. Offer `deployCandidates` when present. The deploy workflow runs these shell commands with `SDLC_ENVIRONMENT` and `SDLC_SHA` exported; the production command is added to `environments.prod.deployCommandPatterns`. Tier 3 requires both commands or `--no-deploy` (run.sh exits 2 otherwise); with `--no-deploy` no deploy workflow is rendered | `--deploy-staging "<cmd>" --deploy-production "<cmd>"` or `--no-deploy` |
| Team mode | `solo`; `team` enables both plugins for teammates through `.claude/settings.json` | `--team solo|team` |
| Cost caps | maxTurns 40, maxBudgetUsd 5, alertThresholdUsd 25 | `--max-turns --max-budget-usd --alert-threshold-usd` |

The interview is complete when every row has a value.

## 3. Render

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init/run.sh" --repo-dir . <flags from the interview>
```

Show `files` grouped by status (installed, merged, unchanged, kept, template-changed, user-edited, missing; artifact directories appear with a trailing `/`) and print `next_steps` verbatim. When `result` is `already-initialised`, report that nothing was written and stop; `/ai-sdlc:sdlc-upgrade` handles template changes. An exit 2 naming `--deploy-staging` / `--deploy-production` means tier 3 needs the deploy commands: ask for them (or for `--no-deploy`) and re-run.

## 4. Human-only platform steps

Skip when platform is `none`. The plugin ships no setup wizard; the reference is `docs/PLATFORM-SETUP.md` in the kit repository (the rendered CI files point there too). Print the numbered steps for the chosen platform as plain text, each with its command or portal path, and say that every one of them needs the human's own terminal or browser (secrets are never typed into an agent session):

GitHub: `gh auth login` (or a fine-grained PAT); `gh secret set ANTHROPIC_API_KEY --repo <owner>/<repo>`; environments `staging` and `production` with required reviewers on `production` (`gh api -X PUT repos/<owner>/<repo>/environments/production -F 'reviewers[][type]=User' -F 'reviewers[][id]=<id>'`); `sdlc-platform branch_protect_apply <branch>`; deploy credentials as environment secrets.

Azure DevOps: `az login` plus `az extension add --name azure-devops` (or a PAT with Work Items read/write, Code read/write, Build read/execute, Project and Team read); variable group `sdlc-secrets` with the secret variable `ANTHROPIC_API_KEY` (`az pipelines variable-group create`, `variable create --secret true`); push the rendered pipelines, then `sdlc-platform ci_workflow_install` and `sdlc-platform branch_protect_apply <branch>`; environments `staging` and `production` with an Approvals check on `production` (portal: Pipelines, Environments); grant the build service `Contribute to pull requests`.

For `both`, print both lists. A team that wants an interactive script may ask for `mattpocock-skills:wizard` over that page, but nothing depends on such a script. Done when the list has been shown to the user.
