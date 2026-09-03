## Ticket

AB#<ticket-id> (spec: `{{ARTIFACTS_DIR}}/features/<slug>/spec.md`)

## What changed

<one paragraph, user-visible behaviour first>

## Evidence

- Verification report: `{{ARTIFACTS_DIR}}/verify/<date>-<sha>.md` (**Verdict:** PASS)
- `{{COMMANDS_VERIFY}}` output tail pasted below
- Code review (`mattpocock-skills:code-review`): Standards <n> findings, Spec <n> findings, all resolved or justified here
- Security review (`sdlc-security-auditor`): Blocking 0, Important <n>, Nit <n>

## Authorship disclosure

- [ ] Parts of this change were written by an agent (list the files or "all")
- [ ] No file in a human-only area (auth, authz, crypto, payments, billing) was agent-authored, or a human adopted it in a review comment

## New dependencies

<package@version and why, or "none">

## Rollback

<how to undo this change if it misbehaves in production>

```
<last lines of the verify command>
```
