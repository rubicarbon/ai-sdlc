---
name: sdlc-security-review
description: "Security check list and report format for reviewing a diff, tuned to what appears in AI-generated code. Use when auditing a change, when REVIEW.md points here, or when asked whether a diff is safe to merge."
---

# Security review of a diff

The list is short on purpose: these are the defects that recur in agent-written code. Walk it once per changed file; report with the format below; rank per `REVIEW.md` (Blocking / Important / Nit, nits capped, findings advisory, a human approves).

## Check list

1. **Injection.** Any string that reaches an interpreter (SQL, shell, template engine, LDAP, path, HTTP header, log line parsed later) is built from parameters or an allowlist, never by concatenating input. Look for `f"..."`, template literals, `+` and `format` next to `execute`, `exec`, `spawn`, `render`, `open`, `path.join`.
2. **Broken access control.** Every new route, handler, job, GraphQL resolver or message consumer names the check that decides who may call it, and the check runs before the work. A new endpoint without one is **Blocking**.
3. **Privilege escalation paths.** A new query, admin flag, feature toggle, background job or "internal" endpoint that reads or writes across tenants or roles without re-checking the caller.
4. **Hardcoded secrets.** Tokens, keys, passwords, connection strings, webhook URLs with embedded credentials, in code, tests, fixtures, CI files, or committed `.env` files. Report the location; never the value.
5. **Unsafe deserialisation and unvalidated input.** `pickle`, `yaml.load` without a safe loader, `eval`, `JSON.parse` of untrusted data straight into behaviour, missing schema validation at a trust boundary, prototype pollution paths.
6. **New dependencies.** Each new or upgraded package: pinned version, known maintainer, justified in the PR body. Typosquat-looking names, unpinned ranges, or install scripts are **Important** at least.
7. **Missing authz on new endpoints** is checked twice on purpose: once as item 2, once here against the route table or router file, because the check is usually missing where the route is registered, not where the handler lives.
8. **Data exposure.** Personal data or credentials in logs, error messages, analytics events, or API responses that did not return them before.
9. **Human-only areas.** Authentication, authorisation, cryptography, payments and billing code is written by a human. Agent-authored changes there are **Blocking** until a human rewrites or explicitly adopts them (a review comment saying so).
10. **Prompt injection surface.** Code that feeds user- or third-party-controlled text into an agent, an LLM call, or a tool invocation without a boundary (quoting, allowlist, or a separate untrusted-content channel).

## Report format

```
# Security review: <PR or branch> against <base>

Blocking: <n>  Important: <n>  Nit: <n> (cap <cap>)

## Blocking
- `path/file.ext:123` — <check name>: <what is wrong>. Fix: <smallest change>.

## Important
- ...

## Nit
- ...

## Dependencies
| Package | Version | Justified in PR | Notes |

## Human-only areas touched
- <file> — <adopted by a human: yes/no>

Findings are advisory; a human code owner approves the merge.
```

## Ranking rules

- **Blocking**: exploitable now, or in a human-only area without human adoption, or a committed secret.
- **Important**: a defect trap that is not exploitable today: unpinned dependency, missing validation behind another check, logging that would leak under a config change.
- **Nit**: hygiene. Respect the cap in `REVIEW.md`; drop the rest, do not list them.
- One finding per root cause. Ten call sites of the same unparameterised query are one Blocking finding with ten locations.
