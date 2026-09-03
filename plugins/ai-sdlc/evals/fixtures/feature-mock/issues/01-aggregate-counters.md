# 01: Aggregate the three counters per account

**What to build:** a nightly job that writes yesterday's active seats, API calls and storage per account into a digest table, so that a later step can render it.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] Running the job for a fixture day produces one row per account with the three counters
- [ ] Re-running the job for the same day is idempotent
