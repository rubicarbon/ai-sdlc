# Aggregate digest counters in a nightly job, not on read

Owners open the digest email once a day, but the three counters would need a cross-tenant scan on every open if computed on read. We aggregate once per account at 02:00 UTC into a digest table and render the email from that table; the counters are a day stale by design, and the job is idempotent per day so a re-run after a failure is safe.
