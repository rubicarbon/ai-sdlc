---
description: "Ship an approved PR: run every release gate, write the release note and rollback rehearsal, obtain human release authorisation, then run the deploy command."
disable-model-invocation: true
argument-hint: "<pr-id> [--version <tag>]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/ship/preflight.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/init/render.sh *), Bash(sdlc-platform pr_get *), Bash(sdlc-platform pr_checks *), Bash(git log *), Bash(git rev-parse *), Bash(git describe *), Bash(git tag *), Bash(ls .sdlc/verify *), Bash(cat .sdlc/verify/*), Bash(jq *), Bash(mkdir -p .sdlc/releases)
---

Ship the pull request whose id is in `$ARGUMENTS` (ask for it when missing). Load `ai-sdlc:sdlc-ship` first; it defines the gates, the evidence and the release note fields.

1. Preflight:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/ship/preflight.sh" --pr <id>
   ```

   When `ready` is false, print every gate with `ok: false` and its `evidence`, name the command that fixes each (from the skill), and stop. The last gate, `release authorised for HEAD`, is expected to fail on this first run.

2. Gather evidence: `sdlc-platform pr_get <id>` (title, `review_decision`, `merged_at`), `sdlc-platform pr_checks <id>` (`status`, check names), the verification report named in the preflight evidence and the newest `*-security.md` (their Verdict, Commit and Blocking lines), `git log <previous tag>..HEAD --oneline` for the change list, `git describe --tags --abbrev=0` for the previous release. Version: `--version`, else ask. The saved reports must keep their `**Verdict:**` and `**Commit:**` lines exactly as the agents wrote them: the ship stage rejects a report whose Commit is not HEAD, so after every new commit run `/ai-sdlc:sdlc-verify` (and `--security`) again before shipping.

3. Render the release note into `.sdlc/releases/<version>.md` with one `--var` per marker; render.sh fails on any marker left unfilled:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/init/render.sh" "${CLAUDE_PLUGIN_ROOT}/templates/artifacts/release.md.tmpl" --out .sdlc/releases/<version>.md \
     --var RELEASE_VERSION=<value> --var RELEASE_DATE=<value> --var RELEASE_SHA=<value> --var RELEASE_AUTHORISED_BY=<value> \
     --var RELEASE_VERIFY_REPORT=<value> --var RELEASE_CHANGES=<value> --var RELEASE_REVIEW_EVIDENCE=<value> \
     --var RELEASE_SECURITY_EVIDENCE=<value> --var RELEASE_APPROVAL_EVIDENCE=<value> --var RELEASE_CHECKS_EVIDENCE=<value> \
     --var RELEASE_PREVIOUS=<value> --var RELEASE_ROLLBACK_COMMAND=<value> --var RELEASE_ROLLBACK_REHEARSED=<value> \
     --var RELEASE_ROLLBACK_ENV=<value> --var RELEASE_MIGRATIONS=<value> --var RELEASE_WATCH=<value>
   ```

   `REPO_DEFAULT_BRANCH` and `COMMANDS_VERIFY` come from `sdlc.config.json`. `RELEASE_AUTHORISED_BY` is `pending` until step 5, then updated from the marker's `authorised_by=` line. Walk the rollback rehearsal checklist from the skill with the user before filling the `RELEASE_ROLLBACK_*` and `RELEASE_MIGRATIONS` values; a rehearsal that was not performed is written as `not rehearsed`, never invented.

4. Ask the human to authorise. Print exactly this, and say the script refuses to run inside a Claude Code session, so it has to be their own terminal:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/ship/authorize.sh" --sha <HEAD sha> --ttl-minutes 120
   ```

   Wait for them to confirm. Never create, copy or edit anything under `.sdlc/release/`.

5. Re-run preflight. Continue only when `ready` is true.

6. Run the production deploy command: `commands.deployProduction` from `sdlc.config.json` is authoritative (when it is not set, stop and ask the human for the command; do not guess one). Run it with `SDLC_ENVIRONMENT=production` and `SDLC_SHA=<HEAD sha>` exported, as the generated deploy workflow does. It matches `environments.prod.deployCommandPatterns`, and the `gate-production` hook now allows it for this commit until the marker expires. Report the outcome, update `RELEASE_AUTHORISED_BY` and `RELEASE_WATCH` in the release note, and tell the user to commit `.sdlc/releases/<version>.md` and tag the release. Done when the deploy command has run and the release note is complete.
