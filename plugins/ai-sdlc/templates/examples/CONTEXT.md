# usage-digest

The shared language for usage-digest. One tight definition per term; the words to avoid are listed so code, tickets and conversation stay consistent. Grown one term at a time by `mattpocock-skills:domain-modeling` during grilling sessions, never edited in bulk.

## Language

**Verification**:
The single command `pnpm verify` and the acceptance criteria of the active ticket, run by a fresh-context verifier.
_Avoid_: testing (too broad), QA

**Ticket**:
A tracer-bullet slice of a spec, small enough for one session, with explicit blocking edges.
_Avoid_: task, story (the tracker's own type names)

**Digest**:
The nightly email with yesterday's active seats, API calls and storage for one account.
_Avoid_: report, summary email

**Active seat**:
A user who authenticated at least once in the digest's day.
_Avoid_: active user, MAU

**Opt-out**:
The per-account boolean that suppresses the digest. Set by an account owner in settings.
_Avoid_: unsubscribe, mute
