# Diagrams

Source of truth is the `.puml` files here; rendered images are not committed
(`docs/diagrams/out/` is gitignored).

| File | Shows |
| --- | --- |
| `ai-sdlc-flow.puml` | the whole outer loop in three swimlanes (human, agent, deterministic scripts), stage by stage, with the artifact and exit code of each gate |
| `ai-sdlc-hooks.puml` | the four `PreToolUse` hooks and their exact deny rules |
| `ai-sdlc-adapter.puml` | `sdlc-platform` dispatch: platform resolution, mock and dry-run paths, contract exit codes, conformance |

## Previewing in VS Code

The workspace is configured for the `jebbs.plantuml` extension rendering
against a PlantUML server on `localhost` (nothing leaves the machine):

- `.vscode/extensions.json` recommends the extension.
- `.vscode/settings.json` sets `plantuml.render` to `PlantUMLServer` and
  `plantuml.server` to `http://localhost:8080`.
- `.vscode/tasks.json` has **PlantUML server: up** and **PlantUML server: stop**
  (Ctrl+Shift+P, *Tasks: Run Task*).

Start the server once (it is created with `--restart unless-stopped`, so it
comes back with Docker):

```bash
docker run -d --restart unless-stopped --name plantuml-server -p 8080:8080 plantuml/plantuml-server:jetty
```

Then open a `.puml` file and press `Alt+D` for the live preview, or
*PlantUML: Export Current Diagram* to write SVG into `docs/diagrams/out/`.

## Rendering without VS Code

```bash
curl -sS -X POST --data-binary @docs/diagrams/ai-sdlc-flow.puml \
  -H 'Content-Type: text/plain' http://localhost:8080/svg > flow.svg
```

An error in the source comes back as an image whose first lines are the
PlantUML version banner, so a quick syntax check is:

```bash
curl -sS -X POST --data-binary @docs/diagrams/ai-sdlc-flow.puml -H 'Content-Type: text/plain' http://localhost:8080/txt | head -3
```

Two syntax rules bit us while writing these: a `;` inside a multi-line activity
label ends the activity early, and a line starting with `{{` opens an embedded
salt diagram.
