#!/usr/bin/env bash
# pr_create (GitHub): open a pull request from a Markdown body file.
#   pr_create <title> <body-file> <base> <head> [--draft]
set -u
export SDLC_PLATFORM=github
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
title="${1:-}"; body="${2:-}"; base="${3:-}"; head="${4:-}"; shift 4 2>/dev/null || usage_die "pr_create <title> <body-file> <base> <head> [--draft]"
draft=()
while [ $# -gt 0 ]; do case "$1" in --draft) draft=(--draft); shift ;; *) usage_die "pr_create: unknown argument '$1'" ;; esac; done
[ -n "$title" ] && [ -f "$body" ] && [ -n "$base" ] && [ -n "$head" ] || usage_die "pr_create <title> <body-file> <base> <head> [--draft]"
require_gh
repo=$(gh_repo)
url=$(cli gh pr create --repo "$repo" --title "$title" --body-file "$body" --base "$base" --head "$head" "${draft[@]+"${draft[@]}"}") || sdlc_die 1 "gh pr create failed"
id="${url##*/}"; [[ "$id" =~ ^[0-9]+$ ]] || sdlc_die 1 "unexpected gh output: $url"
out_json "$(jq -cn --arg id "$id" --arg url "$url" '{id:$id,url:$url,platform:"github"}')"
