---
description: "Publish a local spec and its tickets to GitHub or Azure DevOps with blocking edges, and write the tracker ids back into the files."
disable-model-invocation: true
argument-hint: "[feature-dir] [--platform github|azure] [--dry-run]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/publish/publish.sh *), Bash(sdlc-platform *), Bash(git status *), Bash(git add *), Bash(git commit *)
---

Publish the feature directory given in `$ARGUMENTS` (when omitted, list the candidates under `.sdlc/features/` and `.scratch/` and ask which one).

Load `ai-sdlc:sdlc-publish` for the procedure, then run:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/publish/publish.sh" <feature-dir> $ARGUMENTS
```

Pass `--dry-run` through when the user asked for it and show the printed commands instead of publishing (a dry run writes nothing, not even the manifest). Pass `--platform github|azure` only when the user named one; without it the script uses `SDLC_PLATFORM`, then `platform` in `sdlc.config.json` (unless `both` or `none`), then the git remote. Exit 1 with a message about `publish-manifest.json` or a file marker naming another platform means the ids already live on that other tracker: show the message and ask the user which platform to continue on; never edit the manifest's `platform` field yourself. Otherwise report the spec url and every ticket url from `publish-manifest.json`, then commit the feature directory with the message `Publish <slug> to <platform>`.
