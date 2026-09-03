# Review policy for usage-digest

Every change arrives as a pull request. Reviews from agents (`mattpocock-skills:code-review`, `ai-sdlc:sdlc-security-auditor`) are **advisory**: they rank findings, they do not approve. A human code owner approves before anything merges to `main` (1 approval(s) required, enforced by branch protection).

## Severity

| Rank | Meaning | Effect |
| --- | --- | --- |
| **Blocking** | Wrong behaviour, a security defect, a violated ADR, or code in a human-only area authored by an agent | The PR does not merge until resolved |
| **Important** | Works, but leaves a defect trap: missing test at the agreed seam, unclear ownership, unhandled failure path | Resolve or justify in the PR before approval |
| **Nit** | Style, naming, wording | At most 5 per review; further nits are dropped, not listed |

Each finding states file and line, the rule it violates (an ADR, a `CONTEXT.md` term, a standard in this file, or a security check), and the smallest fix.

## Human-only areas

Authentication, authorisation, cryptography, payments and billing code are written by a human. An agent may propose a diff in these areas only inside a PR that is labelled `human-authorship-required`, and the security auditor marks any agent-authored change there **Blocking** until a human rewrites or explicitly adopts it in a review comment.

## Security checks (what shows up in agent-written code)

- Injection: SQL, shell, template, path, header. Any string that reaches an interpreter is built from parameters, never concatenation.
- Broken access control: every new endpoint or handler names its authorisation check; missing check is Blocking.
- Privilege escalation paths: role or tenant checks bypassed by a new query, job or admin flag.
- Hardcoded secrets or tokens, including in tests and fixtures.
- Unsafe deserialisation and unvalidated input at trust boundaries.
- New dependencies: each one justified in the PR body, pinned, and with a known maintainer.
- Logging of personal data or credentials.

## Standards

- Tests at the seams agreed in the spec; a change to behaviour changes or adds a test.
- `pnpm verify` passes locally before the PR is opened; the verifier repeats it in a fresh context.
- Domain terms from `CONTEXT.md` in names and messages; a new term goes into `CONTEXT.md` in the same PR.
- A ticket id in the PR title or body; work without a ticket is closed, not reviewed.
