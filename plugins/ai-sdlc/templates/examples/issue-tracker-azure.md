# Issue tracker: Azure DevOps (via `sdlc-platform`)

Issues, specs and tickets for this repo live as **Azure Boards work items** in project `Platform` at `https://dev.azure.com/contoso` (repo `usage-digest`). Every operation goes through the `sdlc-platform` contract provided by the `ai-sdlc` plugin; never call `az` directly. Each call prints one JSON line; read ids and urls from it.

## Conventions

- **Create an issue**: write the Markdown body to a file, then `sdlc-platform work_item_create "<title>" <body-file> --labels <a,b>`. The work item type defaults to `User Story`; add `--type Bug` for defects. Labels become tags.
- **Read an issue**: `sdlc-platform work_item_get <id>` (`state` is `open` or `closed`, `labels` are the tags, `body` is the description as text).
- **Comment on an issue**: `sdlc-platform work_item_comment <id> <body-file>`.
- **Apply / remove labels**: tags are set at creation; to change them afterwards, add a comment naming the new state and ask the maintainer to retag, or use the Azure Boards UI.
- **Close**: comment the outcome, then ask the maintainer to move the item to Closed (state transitions stay human).
- **Pull requests**: `sdlc-platform pr_create "<title>" <body-file> main <head-branch>`, `sdlc-platform pr_get <id>`, `sdlc-platform pr_comment <id> <body-file>`, `sdlc-platform pr_checks <id>`. Link the ticket by writing `AB#<id>` in the PR title or body.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `/triage` reads this flag.)_

## When a skill says "publish to the issue tracker"

Create a work item with `sdlc-platform work_item_create`. For a set of tickets with blocking edges, prefer `/ai-sdlc:sdlc-publish <feature-dir>`, which creates them in dependency order, wires `blocks` edges natively and writes the ids back into the files.

## When a skill says "fetch the relevant ticket"

Run `sdlc-platform work_item_get <id>`.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single work item with **child** work items as tickets.

- **Map**: `sdlc-platform work_item_create "<map title>" <body-file> --labels wayfinder:map --type User Story`.
- **Child ticket**: `sdlc-platform work_item_create "<question title>" <body-file> --labels wayfinder:<type> --parent <map-id>` with `<type>` one of `research`, `prototype`, `grilling`, `task`. Once claimed, the ticket is assigned to the driving dev (Azure Boards UI or a comment naming them).
- **Blocking**: `sdlc-platform work_item_link <blocker-id> <ticket-id> --type blocks` creates the native Predecessor/Successor dependency, visible in the Boards UI. A ticket is unblocked when every predecessor is `closed`.
- **Frontier query**: for each open child (`work_item_get`), drop those whose `body` names an open blocker or that carry an assignee; first in map order wins. The Boards dependency view shows the same frontier visually.
- **Claim**: comment `Claimed by <name>` with `work_item_comment`, then set the assignee in the UI.
- **Resolve**: post the answer with `work_item_comment`, ask the maintainer to close the item, then append a context pointer (gist + link) to the map's Decisions-so-far by editing the map body in the UI or commenting on the map.
