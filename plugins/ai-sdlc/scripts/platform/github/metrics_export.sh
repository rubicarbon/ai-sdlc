#!/usr/bin/env bash
# metrics_export (GitHub): merged PRs, deployments, incidents and reverts -> normalised JSON.
#   metrics_export <since> <until> <out.json>      (dates: YYYY-MM-DD, UTC)
# Every CLI call must succeed and return JSON; a failure ends the export with exit 1 and
# no output file (the file is assembled in a temp location and moved at the end). The one
# exception is a github.deployWorkflow that does not exist on the default branch: that is a
# configuration mistake with a correct fallback (the Deployments API), so it becomes a
# warning. The file records where each series came from ("sources") and any coverage caveats
# ("warnings"). Under --dry-run nothing is written.
set -u
export SDLC_PLATFORM=github
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
since="${1:-}"; until="${2:-}"; out="${3:-}"
[[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$until" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [ -n "$out" ] \
  || usage_die "metrics_export <since YYYY-MM-DD> <until YYYY-MM-DD> <out.json>"
require_gh
repo=$(gh_repo)
incident_label=$(read_config '.metrics.incidentLabel' 'incident')
deploy_workflow=$(read_config '.github.deployWorkflow' '')
deploy_env=$(read_config '.metrics.deployEnvironment' 'production')
max_prs=$(read_config '.metrics.maxPrs' 200)
[[ "$max_prs" =~ ^[1-9][0-9]*$ ]] || max_prs=200
since_ts="${since}T00:00:00Z"; until_ts="${until}T23:59:59Z"
warnings=()

# Pull requests. `gh pr list --json author,reviews,commits` cannot be used: every commit in a
# PR's commits connection carries an authors connection of its own, so the query asks GitHub
# for roughly 10,200 possible nodes per pull request and is rejected outright above ~49 of
# them ("exceeds the maximum limit of 500,000"). This asks for the fields the export actually
# consumes (the PR scalars, author.login, the review timestamps, the commit timestamps) and
# nothing else, which costs about 20,100 possible nodes per page of 100 -- a fixed cost per
# page, whatever metrics.maxPrs says. The search itself is the one gh builds for
# --state merged --search "merged:<since>..<until>".
#
# GraphQL search ignores the `sort:` qualifiers the REST search honours, so the pages come
# back in no useful order. The period is therefore paged to the end (bounded by the search
# API's own 1000-result ceiling) and metrics.maxPrs is applied afterwards, to the newest
# merges: a cap that kept whichever 200 the API happened to return first would make the
# export non-deterministic and silently biased.
PR_QUERY='query($q: String!, $n: Int!, $after: String) {
  search(query: $q, type: ISSUE, first: $n, after: $after) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes { ... on PullRequest {
      number title createdAt mergedAt additions deletions changedFiles
      author { login }
      reviews(first: 100) { nodes { submittedAt } }
      commits(first: 100) { nodes { commit { committedDate } } }
    } }
  }
}'
pr_search="repo:$repo is:pr is:merged merged:$since..$until"
SEARCH_CAP=1000   # the search API never returns more, whatever the period holds
# Each page is normalised to the exported shape and appended to a temp file: a page of 100
# PRs with their reviews and commits is far too big to pass back through a jq argument list.
pages=$(sdlc_tmpfile .jsonl)
fetched=0; matched=0; cursor=""
while [ "$fetched" -lt "$SEARCH_CAP" ]; do
  page=$(( SEARCH_CAP - fetched )); [ "$page" -gt 100 ] && page=100
  gh_args=(api graphql -f query="$PR_QUERY" -f q="$pr_search" -F n="$page")
  [ -n "$cursor" ] && gh_args+=(-f after="$cursor")
  page_json=$(cli_json "gh api graphql <merged pull requests in $repo>" gh "${gh_args[@]}") || { rm -f "$pages"; exit 1; }
  printf '%s' "$page_json" | jq -c '
    if (.data.search.nodes | type) != "array" then error("shape") else [.data.search.nodes[] | {
      id: (.number|tostring), created_at: .createdAt, merged_at: .mergedAt,
      first_review_at: ([(.reviews.nodes // [])[] | .submittedAt | select(. != null)] | min),
      additions, deletions, changed_files: .changedFiles,
      first_commit_at: ([(.commits.nodes // [])[] | .commit.committedDate | select(. != null)] | min),
      author: (.author.login // null), is_revert: ((.title // "") | startswith("Revert"))}] end' >>"$pages" \
    || { rm -f "$pages"; sdlc_die 1 "gh api graphql returned an unexpected shape"; }
  fetched=$(( fetched + $(printf '%s' "$page_json" | jq '.data.search.nodes | length') ))
  matched=$(printf '%s' "$page_json" | jq -r '.data.search.issueCount')
  [ "$(printf '%s' "$page_json" | jq -r '.data.search.pageInfo.hasNextPage')" = true ] || break
  cursor=$(printf '%s' "$page_json" | jq -r '.data.search.pageInfo.endCursor // ""')
  [ -n "$cursor" ] || break
done
# Newest merge first, then the cap: the exported set is the most recent <maxPrs> merges of
# the period, whatever order the search returned them in.
jq -cs --argjson cap "$max_prs" 'add // [] | sort_by(.merged_at // "") | reverse | .[:$cap]' "$pages" >"$pages.capped" \
  && mv "$pages.capped" "$pages" \
  || { rm -f "$pages" "$pages.capped"; sdlc_die 1 "gh api graphql returned an unexpected shape"; }
exported=$(jq 'length' "$pages")
[[ "$matched" =~ ^[0-9]+$ ]] || matched=$fetched
if [ "$matched" -gt "$SEARCH_CAP" ]; then
  warnings+=("$matched pull requests were merged between $since and $until; the GitHub search API returns at most $SEARCH_CAP of them, and metrics.maxPrs then kept the $exported most recently merged")
elif [ "$exported" -lt "$fetched" ]; then
  warnings+=("metrics.maxPrs is $max_prs and $fetched pull requests were merged between $since and $until; only the $exported most recently merged are included")
fi

# Deployments: the configured deploy workflow's runs, else the Deployments API (always
# available on GitHub, so the source is always "configured"). A github.deployWorkflow that
# does not exist on the default branch is a configuration mistake, not an outage (below tier 3
# and under --no-deploy no deploy workflow is rendered), so it degrades to the Deployments API
# with a warning. Every other failure -- auth, rate limit, network -- is still fatal.
from_workflow=0
runs=''; run_err=''   # cli_json_try assigns these by name
if [ -n "$deploy_workflow" ]; then
  if cli_json_try runs run_err gh run list --repo "$repo" --workflow "$deploy_workflow" \
      --limit 200 --json databaseId,conclusion,createdAt,updatedAt,headSha; then
    from_workflow=1
  elif [[ "$run_err" == *"workflow $deploy_workflow not found on the default branch"* ]]; then
    warnings+=("github.deployWorkflow names '$deploy_workflow', which does not exist on the default branch of $repo: deployments come from the GitHub Deployments API instead")
  else
    sdlc_die 1 "gh run list --repo $repo --workflow $deploy_workflow failed: ${run_err:-no error output}"
  fi
fi
if [ "$from_workflow" = 1 ]; then
  deployments=$(printf '%s' "$runs" | jq -c --arg s "$since_ts" --arg u "$until_ts" --arg env "$deploy_env" '
    [.[] | select(.createdAt >= $s and .createdAt <= $u) | {
      id: (.databaseId|tostring), environment: $env, started_at: .createdAt, finished_at: .updatedAt,
      status: (if .conclusion=="success" then "success" elif .conclusion==null then "pending" else "failure" end),
      sha: .headSha}]') || sdlc_die 1 "gh run list returned an unexpected shape"
else
  deps_raw=$(cli_json "gh api repos/$repo/deployments?environment=$deploy_env" gh api --paginate \
    "repos/$repo/deployments?environment=$deploy_env&per_page=100") || exit $?
  deps=$(printf '%s' "$deps_raw" | jq -cs 'add // []')
  deployments='[]'
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    did=$(printf '%s' "$d" | jq -r .id)
    st_raw=$(cli_json "gh api repos/$repo/deployments/$did/statuses" gh api \
      "repos/$repo/deployments/$did/statuses?per_page=1") || exit $?
    st=$(printf '%s' "$st_raw" | jq -r '.[0].state // "pending"')
    deployments=$(printf '%s' "$deployments" | jq -c --argjson d "$d" --arg st "$st" --arg env "$deploy_env" '
      . + [{id: ($d.id|tostring), environment: $env, started_at: $d.created_at, finished_at: $d.updated_at,
            status: (if $st=="success" then "success"
                     elif $st=="pending" or $st=="in_progress" or $st=="queued" then "pending" else "failure" end),
            sha: $d.sha}]')
  done < <(printf '%s' "$deps" | jq -c --arg s "$since_ts" --arg u "$until_ts" '.[] | select(.created_at >= $s and .created_at <= $u)')
fi

issues=$(cli_json "gh issue list --repo $repo --label $incident_label" gh issue list --repo "$repo" \
  --label "$incident_label" --state all --limit 200 --json number,createdAt,closedAt,labels) || exit $?
incidents=$(printf '%s' "$issues" | jq -c --arg s "$since_ts" --arg u "$until_ts" '
  [.[] | select(.createdAt <= $u and (.createdAt >= $s or (.closedAt // "9999") >= $s))
   | {id: (.number|tostring), opened_at: .createdAt, closed_at: .closedAt, labels: [(.labels // [])[] | .name]}]') \
  || sdlc_die 1 "gh issue list returned an unexpected shape"

sdlc_reverts_scan "$since" "$until"
[ -n "$REVERTS_WARNING" ] && warnings+=("$REVERTS_WARNING")

# The series travel to jq in files, not in --argjson: a few hundred pull requests or
# deployments exceed the 32 KB argument list Windows allows for a spawned process.
f_dep=$(sdlc_tmpfile .json); printf '%s' "$deployments" >"$f_dep"
f_inc=$(sdlc_tmpfile .json); printf '%s' "$incidents" >"$f_inc"
f_rev=$(sdlc_tmpfile .json); printf '%s' "$REVERTS_JSON" >"$f_rev"
doc=$(jq -cn --arg repo "$repo" --arg s "$since" --arg u "$until" --arg now "$(sdlc_iso_now)" --arg rev_src "$REVERTS_SOURCE" \
  --slurpfile prs "$pages" --slurpfile dep "$f_dep" --slurpfile inc "$f_inc" --slurpfile rev "$f_rev" \
  --argjson warn "$(json_list "${warnings[@]+"${warnings[@]}"}")" \
  '{platform:"github", repo:$repo, since:$s, until:$u, exported_at:$now,
    sources:{prs:"configured", deployments:"configured", incidents:"configured", reverts:$rev_src},
    warnings:$warn, prs:$prs[0], deployments:$dep[0], incidents:$inc[0], reverts:$rev[0]}')
rm -f "$pages" "$f_dep" "$f_inc" "$f_rev"
[ -n "$doc" ] || sdlc_die 1 "internal error in ${0##*/}: the export document could not be assembled"
if [ "${SDLC_DRY_RUN:-0}" != "1" ]; then
  tmp=$(sdlc_tmpfile .json); printf '%s\n' "$doc" >"$tmp"
  case "$out" in */*) mkdir -p "${out%/*}" ;; esac
  mv "$tmp" "$out" || { rm -f "$tmp"; sdlc_die 1 "cannot write $out"; }
fi
out_json "$(printf '%s' "$doc" | jq -c --arg out "$out" '{prs:(.prs|length), deployments:(.deployments|length),
  incidents:(.incidents|length), reverts:(.reverts|length), out:$out, warnings:.warnings, platform:"github"}')"
