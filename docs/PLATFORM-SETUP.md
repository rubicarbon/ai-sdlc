# Platform setup: the steps only a human can perform

`/ai-sdlc:sdlc-init` renders files into the repository. It does not, and cannot, create secrets, environments, approval rules or pipeline registrations on GitHub or Azure DevOps: those need an account with administrative rights, and the agent holds none. This page lists every manual step, in order, with the exact command or portal path, and how to check it. The plugin ships no setup wizard; `next_steps` in the init output points here.

Run the steps for your platform after the tier that needs them:

| Tier | Needs |
| --- | --- |
| 0 and 1 | CLI login only (`gh auth login` or `az login` plus `az extension add --name azure-devops`) |
| 2 | branch protection or branch policies (section 3 or 7) |
| 3 | the `ANTHROPIC_API_KEY` secret, the `staging` and `production` environments with a human approval on `production`, and the deploy commands in `sdlc.config.json` (sections 2, 4, 5 and 8, 9, 10) |

## GitHub

### 1. Authenticate the CLI

```bash
gh auth login
gh auth status
```

For a fine-grained personal access token instead, grant on the repository: Issues read and write, Pull requests read and write, Contents read, Administration read and write (branch protection), Actions read, Deployments read. `docs/SECURITY.md` explains why each scope is needed.

### 2. Repository secret `ANTHROPIC_API_KEY`

The `sdlc-pr-review` workflow reads it. Set it from your own terminal, never from an agent session, and never commit it:

```bash
gh secret set ANTHROPIC_API_KEY --repo <owner>/<repo>
```

The command prompts for the value on stdin. Check: `gh secret list --repo <owner>/<repo>` lists `ANTHROPIC_API_KEY`.

### 3. Branch protection

```bash
sdlc-platform branch_protect_apply <default-branch>
```

This applies `templates/github/branch-protection.json` rendered with `review.requiredApprovals` and `github.requiredChecks`: code-owner reviews required, stale reviews dismissed, last-push approval, conversation resolution, no force pushes, admins included. It needs the Administration scope. Check: the output lists the fields under `applied` (first run) or `updated`, and a second run reports everything under `unchanged`. In the portal: Settings, Branches, the rule for the default branch.

### 4. Environments with a human gate

Create the two environments the deploy workflow uses and put required reviewers on `production`:

```bash
gh api -X PUT "repos/<owner>/<repo>/environments/staging"
gh api -X PUT "repos/<owner>/<repo>/environments/production" \
  -F 'reviewers[][type]=User' -F 'reviewers[][id]=<user id>'
```

The numeric user id comes from `gh api users/<login> --jq .id`; a team reviewer uses `type=Team` and the team id. Portal path: Settings, Environments, New environment, then "Required reviewers". Check: `gh api repos/<owner>/<repo>/environments/production --jq '.protection_rules[].type'` prints `required_reviewers`. Without this rule the production job of `sdlc-deploy.yml` runs unattended.

### 5. Deploy commands

`sdlc-deploy.yml` runs `commands.deployStaging` and `commands.deployProduction` from `sdlc.config.json`, with `SDLC_ENVIRONMENT` and `SDLC_SHA` exported. Set them at init (`--deploy-staging`, `--deploy-production`) or edit the config and re-run `run.sh --upgrade`. Deploy credentials belong in the environment's secrets (Settings, Environments, Environment secrets), which only jobs in that environment can read.

### 6. Workflow permissions

Settings, Actions, General, Workflow permissions: "Read and write permissions" is not needed; the templates declare per-job permissions. Enable "Allow GitHub Actions to create and approve pull requests" only if your own workflows need it; the ai-sdlc review comments, it never approves.

## Azure DevOps

### 7. Authenticate the CLI

```bash
az login
az extension add --name azure-devops
az devops configure --defaults organization=https://dev.azure.com/<org> project=<project>
```

For a personal access token instead, export `AZURE_DEVOPS_EXT_PAT` with scopes Work Items read and write, Code read and write, Build read and execute, Project and Team read.

### 8. Variable group `sdlc-secrets`

`sdlc-pr-review.yml` links the variable group `sdlc-secrets` and reads `ANTHROPIC_API_KEY` from it as a secret variable:

```bash
az pipelines variable-group create --name sdlc-secrets --authorize true \
  --variables placeholder=1
az pipelines variable-group variable create --group-id <id> --name ANTHROPIC_API_KEY \
  --secret true --value "<key>"
az pipelines variable-group variable delete --group-id <id> --name placeholder --yes
```

Type the key into your own terminal; do not paste it into an agent session. Portal path: Pipelines, Library, Variable groups. Check: `az pipelines variable-group list -o table` shows `sdlc-secrets`, and the variable is marked secret.

### 9. Register the pipelines, then the branch policies

Commit and push the rendered `.azuredevops/pipelines/*.yml` to the default branch first, then:

```bash
sdlc-platform ci_workflow_install
sdlc-platform branch_protect_apply <default-branch>
```

`ci_workflow_install` registers `sdlc-pr-review`, `sdlc-deploy` and `sdlc-evals` with `az pipelines create --skip-first-run`. `branch_protect_apply` creates or updates the approver-count, required-reviewer (from `azure.requiredReviewers`; Azure Repos has no CODEOWNERS), work-item-linking, comment-required and build policies, and reports `applied`, `updated`, `unchanged` and `skipped`; the build policy is skipped until the review pipeline is registered, which is why the order matters.

### 10. Environments with an Approvals check

Pipelines, Environments, New environment: create `staging` and `production`. On `production`, open Approvals and checks, add "Approvals", and name the approvers. The CLI has no command for environment checks; this is a portal step. Check: the `production` stage of a `sdlc-deploy` run waits for an approver before it starts.

### 11. Build service permissions

The review pipeline posts comments with `System.AccessToken`. Project settings, Repositories, the repository, Security: grant "<project> Build Service (<org>)" the permission "Contribute to pull requests" (Allow). Without it `sdlc-platform pr_comment` exits 1 from the pipeline with the REST error text.

### 12. Deploy commands

As on GitHub: `commands.deployStaging` and `commands.deployProduction` in `sdlc.config.json` are what `sdlc-deploy.yml` runs, with `SDLC_ENVIRONMENT` and `SDLC_SHA` exported. Service connections and deploy secrets belong to the pipeline's environment or a separate variable group, not to the repository.

## Both platforms: release authorisation

Shipping also needs the human authorisation marker, created at your own terminal (the script refuses to run inside a Claude Code session):

```bash
bash <plugin-root>/scripts/ship/authorize.sh --sha HEAD --ttl-minutes 120
```

`/ai-sdlc:sdlc-ship` asks for it at the right moment; `docs/SECURITY.md` and `plugins/ai-sdlc/skills/sdlc-ship/SKILL.md` describe what the marker must contain.
