#!/usr/bin/env bash
# branch_protect_apply (GitHub): PUT branch protection rendered from
# templates/github/branch-protection.json. Idempotent: compares the fields it
# manages with the current protection and only writes when they differ.
set -u
export SDLC_PLATFORM=github
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
branch="${1:-}"; [ -n "$branch" ] || usage_die "branch_protect_apply <branch>"
require_gh
repo=$(gh_repo)

approvals=$(read_config '.review.requiredApprovals' 1)
checks_json=$(read_config '.github.requiredChecks' '[]'); printf '%s' "$checks_json" | jq -e 'type=="array"' >/dev/null 2>&1 || checks_json='[]'
desired=$(bash "$SDLC_PLUGIN_ROOT/scripts/init/render.sh" "$SDLC_PLUGIN_ROOT/templates/github/branch-protection.json" \
  --var "REVIEW_REQUIRED_APPROVALS=$approvals" --var "GITHUB_REQUIRED_CHECKS_JSON=$checks_json" ${SDLC_CONFIG:+--config "$SDLC_CONFIG"}) || sdlc_die 1 "could not render branch-protection.json"

# Reduce both the desired body and GitHub's response (booleans wrapped in {enabled}) to one comparable shape.
reduce='def b: if type=="object" then (.enabled // false) else (. // false) end;
{ strict: (.required_status_checks.strict // false),
  contexts: ((.required_status_checks.contexts // []) | sort),
  enforce_admins: (.enforce_admins | b),
  dismiss_stale_reviews: (.required_pull_request_reviews.dismiss_stale_reviews // false),
  require_code_owner_reviews: (.required_pull_request_reviews.require_code_owner_reviews // false),
  required_approving_review_count: (.required_pull_request_reviews.required_approving_review_count // 0),
  require_last_push_approval: (.required_pull_request_reviews.require_last_push_approval // false),
  allow_force_pushes: (.allow_force_pushes | b), allow_deletions: (.allow_deletions | b),
  required_conversation_resolution: (.required_conversation_resolution | b),
  required_linear_history: (.required_linear_history | b), lock_branch: (.lock_branch | b) }'
want=$(printf '%s' "$desired" | jq -c "$reduce")
current=$(gh api "repos/$repo/branches/$branch/protection" 2>/dev/null | jq -c "$reduce" 2>/dev/null)
[ -n "$current" ] || current='{}'      # 404 = branch not protected yet (jq prints nothing on empty input)

changed=$(jq -cn --argjson w "$want" --argjson c "$current" '[$w | to_entries[] | select($c[.key] != .value) | .key]')
unchanged=$(jq -cn --argjson w "$want" --argjson c "$current" '[$w | to_entries[] | select($c[.key] == .value) | .key]')
if [ "$(printf '%s' "$changed" | jq 'length')" -gt 0 ]; then
  tmp=$(sdlc_tmpfile .json); printf '%s' "$desired" >"$tmp"
  cli gh api --method PUT "repos/$repo/branches/$branch/protection" --input "$tmp" >/dev/null || { rm -f "$tmp"; sdlc_die 1 "gh api PUT branch protection failed (admin scope required)"; }
  rm -f "$tmp"
fi
out_json "$(jq -cn --arg b "$branch" --argjson a "$changed" --argjson u "$unchanged" '{branch:$b,applied:$a,unchanged:$u,skipped:[],platform:"github"}')"
