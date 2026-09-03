#!/usr/bin/env bash
# pr_create (Azure DevOps): open a pull request from a Markdown body file.
#   pr_create <title> <body-file> <base> <head> [--draft]
set -u
export SDLC_PLATFORM=azure
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
title="${1:-}"; body="${2:-}"; base="${3:-}"; head="${4:-}"; shift 4 2>/dev/null || usage_die "pr_create <title> <body-file> <base> <head> [--draft]"
draft=()
while [ $# -gt 0 ]; do case "$1" in --draft) draft=(--draft true); shift ;; *) usage_die "pr_create: unknown argument '$1'" ;; esac; done
[ -n "$title" ] && [ -f "$body" ] && [ -n "$base" ] && [ -n "$head" ] || usage_die "pr_create <title> <body-file> <base> <head> [--draft]"
require_az; az_context
desc=$(<"$body")
raw=$(cli az repos pr create --repository "$AZ_REPO" --source-branch "$head" --target-branch "$base" --title "$title" --description "$desc" "${draft[@]+"${draft[@]}"}" "${AZ_ARGS[@]}" -o json) || sdlc_die 1 "az repos pr create failed"
id=$(printf '%s' "$raw" | jq -r '.pullRequestId'); web=$(printf '%s' "$raw" | jq -r '.repository.webUrl // empty')
[[ "$id" =~ ^[0-9]+$ ]] || sdlc_die 1 "unexpected az output: ${raw:0:200}"
[ -n "$web" ] || web="$AZ_ORG/$AZ_PROJECT/_git/$AZ_REPO"
out_json "$(jq -cn --arg id "$id" --arg url "$web/pullrequest/$id" '{id:$id,url:$url,platform:"azure"}')"
