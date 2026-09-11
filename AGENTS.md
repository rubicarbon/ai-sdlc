# AGENTS.md

Validation policy for work on this repository. It governs this repository only; the
instructions that `/ai-sdlc:sdlc-init` renders into consumer projects are unaffected.

## Local checks

Run the quick checks and the focused tests that cover the behaviour you changed:

- `bash -n` over each shell file you touched.
- The eval cases that cover the change, selected with the runner's filter — it matches a
  substring of the case file name, and several words are allowed:
  `bash plugins/ai-sdlc/evals/run.sh <word> [<word> ...]`. The case names are the file names
  under `plugins/ai-sdlc/evals/cases/`.
- For `report.py`: `python -B -m unittest discover -s plugins/ai-sdlc/evals/python`.
- For manifest changes: `claude plugin validate . --strict`.

Adapter changes run the specific adapter cases through the filtered runner —
`adapters-conformance`, `platform-dry-run`, and the `azure-*` cases — not
`scripts/platform/conformance.sh`. Narrowing conformance to one platform does not make it a
light check: `--platform github` still runs every contract function for that platform.

Do not run the full eval suite or adapter conformance locally unless the user explicitly asks.
The unfiltered suite takes about fifteen minutes on Windows, because every `jq` call is a
separate process, and CI runs both in full on every pull request.

## Changes that skip behavioural tests

Explanatory text only: prose that does not alter agent instructions, templates, configuration,
or executable behaviour. Review the change against the sources named above and stop there.

A Markdown file is not automatically exempt. `plugins/ai-sdlc/commands/*.md` and
`plugins/ai-sdlc/skills/**` are agent instructions, and everything under
`plugins/ai-sdlc/templates/` is rendered into consumer projects. Editing those changes
behaviour and takes the focused tests above.

## Full validation

`.github/workflows/ci.yml` runs the whole eval suite, adapter conformance for both platforms,
the Python unit tests, `shellcheck -S warning`, a YAML parse of every rendered CI template,
`actionlint`, and `claude plugin validate --strict` on both manifests. It runs on pull requests
and on pushes to `main`. Whether it blocks a merge depends on branch protection, which this
policy does not assume.
