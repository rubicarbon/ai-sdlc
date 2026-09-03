---
description: "Apply ai-sdlc template changes after a plugin update: diff every template-changed managed file, ask per file, then re-render. Never overwrites a user-edited file."
disable-model-invocation: true
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/init/run.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/init/render.sh *), Bash(mkdir -p .sdlc/tmp), Bash(diff -u *), Bash(rm -rf .sdlc/tmp), Bash(jq *)
---

Bring the managed files up to the installed plugin version without losing anyone's edits.

1. Find the drift:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/init/run.sh" --repo-dir . --check
   ```

   Exit 0 with `result: clean` means nothing to do; say so and stop. Otherwise read `pending[]` (`status` is `template-changed` or `missing`) and `user_edited[]`.

2. For each `template-changed` entry, render the new version to a scratch file and show the difference:

   ```
   mkdir -p .sdlc/tmp
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/init/render.sh" "${CLAUDE_PLUGIN_ROOT}/templates/<template>" --config sdlc.config.json --out .sdlc/tmp/<basename>
   diff -u <path> .sdlc/tmp/<basename>
   ```

   `template` and `path` come from the entry. `REVIEW.md` needs `--var REVIEW_NIT_CAP=<review.nitCap>`; `.azuredevops/branch-policies.json` needs `--var REVIEW_REQUIRED_APPROVALS=<review.requiredApprovals> --var AZURE_PIPELINE_NAME=<azure.pipelineName>`. `CLAUDE.md` and `.claude/settings.json` are maintained as a managed block and a merge, so describe the change from the rendered template instead of a raw diff. Ask with AskUserQuestion: apply or leave, one question per file.

3. Apply only what was accepted. `--only <path>` (repeatable) limits the upgrade to those files; declined files stay `template-changed` and are listed again next time:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/init/run.sh" --repo-dir . --upgrade --only <path> [--only <path>...]
   ```

   Without `--only`, `--upgrade` re-renders every template-changed file. `missing` files are re-created by any run without `--check`.

4. `user_edited[]` files are reported and kept. Explain that the template moved on but their edits win, and that `run.sh --force` overwrites them: a human runs that in their own terminal after backing up the file. Never run `--force` yourself.

5. Remove `.sdlc/tmp`, show the `files` list from the last run, and remind the user to commit. Done when every pending file is either upgraded or explicitly left with its diff shown.
