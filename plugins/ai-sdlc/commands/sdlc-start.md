---
description: "Frame a change before any code: relentless grilling plus domain modelling, then hand off to /mattpocock-skills:to-spec."
disable-model-invocation: true
argument-hint: "[one-line description of the change]"
---

Frame the change described in `$ARGUMENTS` (ask for one sentence if it is empty).

1. Call the Skill tool with `mattpocock-skills:grilling` and again with `mattpocock-skills:domain-modeling`. Interview until every branch of the design is resolved; record resolved terms in `CONTEXT.md` and hard-to-reverse decisions as ADRs under `docs/adr/` as they crystallise.
2. When the interview ends, summarise the decisions in ten lines or fewer and tell the user to type `/mattpocock-skills:to-spec`. That skill is user-invoked; you cannot call it.
3. After the spec exists, the next stage is `/mattpocock-skills:to-tickets`, then `/ai-sdlc:sdlc-publish` when the platform is GitHub or Azure DevOps. Point at `ai-sdlc:sdlc-loop` for the full route.

If `mattpocock-skills` is not installed, stop and say so: run `/plugin install mattpocock-skills`, then retry.
