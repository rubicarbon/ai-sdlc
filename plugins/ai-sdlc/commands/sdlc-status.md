---
description: "Show the SDLC state of this repo: config validity, tier, platform, template drift, mattpocock-skills drift, stage readiness, features in flight and release authorisations."
disable-model-invocation: true
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/init/status.sh *), Bash(jq *)
---

Report the SDLC state of the current repository from one script call; add no facts the JSON does not contain.

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init/status.sh" --repo-dir .
```

When `initialised` is false, say the repo is not an ai-sdlc project and point to `/ai-sdlc:sdlc-init`; stop.

Otherwise present, in this order:

| Section | Fields | What to say |
| --- | --- | --- |
| Config | `config.valid`, `config.errors`, `platform`, `tier`, `team`, `verify` | one line per field; list every error verbatim |
| Plugin version | `config.renderedBy` vs `config.pluginVersion`, `upgradeAvailable` | when they differ, recommend `/ai-sdlc:sdlc-upgrade` |
| Drift | `drift.result` (`clean`, `drift`, `unknown`), `drift.pending[]` (`path`, `status` = `template-changed` or `missing`) | list each pending file; any `template-changed` entry also earns the `/ai-sdlc:sdlc-upgrade` pointer |
| Inner loop | `mattpocock.installed`, `installed_version` vs `expected_version`, `missing`, `retyped`, `editable_copies`, `drift` | not installed: `/plugin install mattpocock-skills`; drift: the `ai-sdlc:sdlc-loop` routing table is stale, see `docs/REUSE.md` |
| Stages | `stages.tickets|build|verify|ship` with `ready` and `reason` | a table: stage, ready, reason (the reason names the command that unblocks it) |
| Work in flight | `features[]`, `verifyReports` | the feature directories under the artifacts dir and how many verification reports exist |
| Releases | `releaseAuthorisations[]` (commit shas) | list them; each is valid only until the expiry inside the marker file |
| Review | `review.runner`, `review.launches[]` (launch id, pr, state, detail), `review.retirePending[]`, `review.migrationPending` | with runner `local`: list every launch that has not reached a terminal state (the author waits for `posted`); name retired review files still present; when the migration is pending say to run `sdlc-platform branch_protect_apply <branch>` |

Close with the first stage whose `ready` is false and its `reason`: that is the next thing to do. Done when every section above has been printed.
