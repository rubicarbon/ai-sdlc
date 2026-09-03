---
description: "Show whether this repo is an ai-sdlc project, its tier, config validity and the next stage."
disable-model-invocation: true
allowed-tools: Bash(test *), Bash(cat sdlc.config.json), Bash(jq *)
---

Report the SDLC state of the current repository.

1. Check for `sdlc.config.json` in the working directory. If it is missing, say so and point to `/ai-sdlc:sdlc-init`; stop.
2. Print `platform`, `tier`, `team.mode` and `commands.verify` from the config in one line each.
3. Name the next stage: read the router in the `ai-sdlc:sdlc-loop` skill and report which artifact is missing first.
