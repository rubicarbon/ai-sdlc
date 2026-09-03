---
description: "Write a blameless postmortem for an incident: timeline from the tracker and git, cause interview, action items published as work items, defect-escape stage recorded for metrics."
disable-model-invocation: true
argument-hint: "<incident-ticket-id or short title> [--pr <id>] [--release <version>]"
allowed-tools: Bash(sdlc-platform work_item_get *), Bash(sdlc-platform pr_get *), Bash(sdlc-platform work_item_create *), Bash(sdlc-platform work_item_link *), Bash(sdlc-platform work_item_comment *), Bash(git log *), Bash(git tag *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/init/render.sh *), Bash(jq *), Bash(mkdir -p .sdlc/postmortems), Bash(cat .sdlc/releases/*), Bash(ls .sdlc/releases *)
---

Produce `.sdlc/postmortems/<YYYY-MM-DD>-<slug>.md` for the incident named in `$ARGUMENTS`. Load `ai-sdlc:sdlc-postmortem` first: it holds the blameless rules, the action types and the defect-escape stages.

1. Gather the timeline. Fetch the incident with `sdlc-platform work_item_get <id>` (`created_at`, `closed_at`, `labels`, `body`), the offending change with `sdlc-platform pr_get <pr>` (`created_at`, `merged_at`, `review_decision`), the release note under `.sdlc/releases/` when `--release` is given, and `git log --since=<incident date minus 2 days> --until=<closed_at> --format='%H %cI %s'` for commits, reverts and hotfixes. Each timeline row cites its source (tracker, PR, git, human). When the platform is `none`, ask the human for the tracker facts.

2. Interview for causes by calling the Skill tool with `mattpocock-skills:grilling`, scoped to: what signal was missing, which stage of the loop should have caught the defect, what made the recovery slow, what went well. Stop the interview when each cause has at least one candidate action. Use `mattpocock-skills:research` when a cause points at an external dependency or a platform behaviour.

3. Agree the actions with the user. Every action carries a type from the skill (`guardrail`, `verification`, `process`), an owner and a ticket cell. Publish each one as a work item labelled `postmortem-action` (never the incident label: `metrics_export` counts everything carrying `metrics.incidentLabel` as an incident) and link it to the incident:

   ```
   sdlc-platform work_item_create "<action title>" <body-file> --labels postmortem-action,ready-for-agent
   sdlc-platform work_item_link <incident-id> <new-id> --type related
   ```

   Put the returned id and url into the ticket cell. With platform `none`, write the actions as tickets under `.sdlc/features/<slug>-postmortem/issues/`.

4. Render the document; every marker is a `--var`, and render.sh fails when one is missing:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/init/render.sh" "${CLAUDE_PLUGIN_ROOT}/templates/artifacts/postmortem.md.tmpl" --out .sdlc/postmortems/<date>-<slug>.md \
     --var INCIDENT_TITLE=<value> --var INCIDENT_DATE=<value> --var INCIDENT_SEVERITY=<value> --var INCIDENT_DURATION=<value> --var AUTHOR=<value> \
     --var INCIDENT_TICKET=<value> --var INCIDENT_RELEASE=<value> --var INCIDENT_SUMMARY=<value> --var INCIDENT_TIMELINE=<value> \
     --var INCIDENT_IMPACT=<value> --var INCIDENT_CAUSES=<value> --var INCIDENT_WENT_WELL=<value> --var INCIDENT_ACTIONS=<value> --var INCIDENT_ESCAPED_STAGE=<value>
   ```

   `INCIDENT_TIMELINE` and `INCIDENT_ACTIONS` are complete Markdown table rows (`| a | b | c |`, newline-separated). `DATE` is filled by render.sh. Read the file back and check that no person is named as a cause.

5. Tag the incident so the metrics export counts it: add a comment to the incident work item with `sdlc-platform work_item_comment <id> <file>` containing the postmortem path and the escaped stage, and confirm the item carries the `metrics.incidentLabel` label (say so when it does not; labels on existing items are edited by a human on the tracker). Tell the user to commit the postmortem. Done when the file exists, every action has a ticket id and the incident carries the comment.
