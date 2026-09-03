#!/usr/bin/env bash
# pr_checks (Azure DevOps): branch policy evaluations of a PR as normalised checks.
# Exit 0 pass, 1 fail, 8 pending.
set -u
export SDLC_PLATFORM=azure
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
id="${1:-}"; [[ "$id" =~ ^[0-9]+$ ]] || usage_die "pr_checks <id>"
require_az; az_context
raw=$(cli az repos pr policy list --id "$id" "${AZ_ARGS[@]}" -o json) || sdlc_die 1 "az repos pr policy list $id failed"
result=$(printf '%s' "$raw" | jq -c --arg id "$id" --arg build "$AZ_ORG/$AZ_PROJECT/_build/results?buildId=" '
  def norm: ascii_downcase | if .=="approved" then "pass" elif IN("rejected","broken") then "fail" elif .=="notapplicable" then "skipped" else "pending" end;
  [.[] | {
    name: ((.configuration.type.displayName // "policy") + (if .configuration.settings.displayName then " (" + .configuration.settings.displayName + ")" else "" end)),
    status: ((.status // "queued") | norm),
    url: (if .context.buildId then ($build + (.context.buildId|tostring)) else null end)}] as $c
  | {id: $id, status: (if any($c[]; .status=="fail") then "fail" elif any($c[]; .status=="pending") then "pending" else "pass" end), checks: $c, platform: "azure"}')
out_json "$result"
case "$(printf '%s' "$result" | jq -r .status)" in fail) exit 1 ;; pending) exit 8 ;; *) exit 0 ;; esac
