# Spec: Nightly usage digest

## Problem Statement

Account owners cannot see how much their team used the product yesterday without opening three dashboards.

## Solution

A nightly digest email with the three numbers owners already look for: active seats, API calls, and storage.

## User Stories

1. As an account owner, I want a daily email with yesterday's active seats, so that I can spot unused licences.
2. As an account owner, I want the same email to show API calls and storage, so that I stop opening dashboards.
3. As an account owner, I want to opt out per account, so that noisy accounts stay quiet.

## Implementation Decisions

- A scheduled job aggregates the three counters per account at 02:00 UTC.
- The email is rendered from one template; no per-customer branding.
- Opt-out is a boolean on the account, exposed in account settings.

## Testing Decisions

- Test the aggregation at the job seam with a fixture day of events.
- Test opt-out at the account settings API seam.

## Out of Scope

Weekly digests, charts, and per-user emails.
