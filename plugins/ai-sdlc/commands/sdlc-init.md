---
description: "Initialise or re-run ai-sdlc in the current repository: detect the platform and stack, interview, render the tier's files, and generate the human setup wizard. The only command that writes into the user's repo."
disable-model-invocation: true
argument-hint: "[--platform github|azure|both|none] [--tier 0-3] [--team solo|team] [--verify <cmd>] [--envs dev,staging,prod] [--azure-org <url> --azure-project <p> --azure-repo <r>] [--yes]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/init/detect.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/init/run.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/reuse/check-mattpocock.sh *), Bash(jq *)
---

Set up the SDLC loop in the repository at the working directory. Everything written goes through `scripts/init/run.sh`; you never write the files by hand.

## 1. Detect

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init/detect.sh" --repo-dir .
```

Read the JSON: `platform`, `repo.owner`/`repo.name`, `azure.*`, `cli.gh`/`cli.az` (present, authenticated, `devopsExtension`), `stack`, `verifyCandidates`, `mattpocock.installed`/`editable_copies`, `existing.config`. When `existing.config` is true, skip to step 3: run.sh is idempotent and reports the state.

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
| Team mode | `solo`; `team` enables both plugins for teammates through `.claude/settings.json` | `--team solo|team` |
| Cost caps | maxTurns 40, maxBudgetUsd 5, alertThresholdUsd 25 | `--max-turns --max-budget-usd --alert-threshold-usd` |

The interview is complete when every row has a value.

## 3. Render

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init/run.sh" --repo-dir . <flags from the interview>
```

Show `files` grouped by status (installed, merged, unchanged, kept, template-changed, user-edited) and print `next_steps` verbatim. When `result` is `already-initialised`, report that nothing was written and stop; `/ai-sdlc:sdlc-upgrade` handles template changes.

## 4. Human setup wizard

Skip when platform is `none`. Otherwise call the Skill tool with `mattpocock-skills:wizard` and ask it to author `scripts/sdlc-setup-wizard.sh` with these stages, in order:

GitHub: authenticate `gh` (or create a fine-grained PAT); set repository secret `ANTHROPIC_API_KEY`; create environments `staging` and `production` with required reviewers on `production`; protect the default branch with `sdlc-platform branch_protect_apply <branch>`; confirm Actions permissions allow workflows to create PRs and comments.

Azure DevOps: create a PAT with scopes Work Items read/write, Code read/write, Build read/execute; create variable group `sdlc-secrets` holding `ANTHROPIC_API_KEY`; create environments `staging` and `production` with an Approvals check on `production`; grant the build service `Contribute to pull requests`; run `sdlc-platform ci_workflow_install` then `sdlc-platform branch_protect_apply <branch>`.

For `both`, include both lists. If `mattpocock-skills` is not installed, print the stage list as numbered plain steps instead and say the wizard can be generated after installing it. Done when the wizard path (or the plain list) has been shown to the user.
