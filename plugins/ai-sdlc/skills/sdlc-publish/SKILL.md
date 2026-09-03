---
name: sdlc-publish
description: "Push a local spec and tickets (the files /mattpocock-skills:to-spec and /to-tickets write) to GitHub or Azure DevOps with blocking edges intact, and write the tracker ids back into the files. Use when a feature directory exists locally but its items are not on the tracker yet, or to repair missing edges after a partial publish."
---

# Publish a feature to the tracker

The deterministic core is a script; run it rather than calling the adapter item by item:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/publish/publish.sh" <feature-dir> [--platform github|azure] [--dry-run]
```

`<feature-dir>` holds `spec.md` and `issues/NN-<slug>.md`. That is the local-tracker layout of `to-spec` and `to-tickets` (`.scratch/<slug>/`) and the layout `ai-sdlc` keeps under `.sdlc/features/<slug>/`.

What the script does, in order:

1. Creates the spec as a work item labelled `spec, ready-for-agent` (skipped when `publish-manifest.json` already records it).
2. Creates one work item per ticket, in file order, each with the spec as parent and the ticket's `Status:` as label.
3. Second pass: for every `Blocked by: 01, 02` line, applies `work_item_link <blocker> <ticket> --type blocks`. On Azure that is a native Successor link; on GitHub a native dependency, with a `Blocked by: #n` body line when the API is unavailable.
4. Writes `<!-- sdlc-publish: id=… url=… platform=… -->` as the first line of every published file and records everything in `publish-manifest.json`.

Re-running is safe: published items are skipped, edges are re-applied (the contract makes duplicates a no-op), markers are replaced, never duplicated.

## Preview first

`--dry-run` prints every CLI command the adapters would run and writes nothing. Show that to the user when the feature has many tickets or when the platform was just configured.

## After publishing

- Report the spec url and each ticket url to the user.
- Commit the feature directory: the markers and the manifest are what keep the loop traceable.
- Move to the build stage through `ai-sdlc:sdlc-loop`; `precondition.sh build` now passes.

## When something fails

Exit 1 names the failing item; the manifest already holds what succeeded, so fixing the cause (usually authentication, or a missing work item type on Azure) and re-running finishes the job. Exit 3 means the platform is `none`: local files are the tracker, and there is nothing to publish.
