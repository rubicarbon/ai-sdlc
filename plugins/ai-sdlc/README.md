# ai-sdlc

Claude Code plugin that turns a software project into an AI-native SDLC workspace. It supplies the outer loop (platform adapters for GitHub and Azure DevOps, deterministic hooks, CI review, metrics, evals) around the inner loop provided by the `mattpocock-skills` plugin.

Install from the `ai-sdlc-kit` marketplace:

```
/plugin marketplace add gergely-somogyvari/ai-sdlc-kit
/plugin install ai-sdlc@ai-sdlc-kit
/ai-sdlc:sdlc-init
```

See the repository root `README.md` for the quickstart and `docs/` for architecture, reuse map, adoption, metrics and security notes.
