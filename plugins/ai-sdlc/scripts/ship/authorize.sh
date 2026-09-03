#!/usr/bin/env bash
# authorize.sh — a HUMAN records release authorisation for one commit.
#
#   authorize.sh [--sha <sha|HEAD>] [--ttl-minutes 120] [--by <name>]
#
# Writes <artifacts>/release/AUTHORIZED-<sha> with who, when and an expiry. gate-production.sh
# lets production-affecting commands through only while that file exists, is for HEAD, and has
# not expired. The file is protected from the agent: the protected-paths hook denies writes
# under <artifacts>/release/, and this script refuses to run inside a Claude Code tool call,
# so the authorisation always comes from a person at their own terminal.
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
. "$SDLC_PLUGIN_ROOT/scripts/_project.sh"
if [ -n "${CLAUDECODE:-}" ] || [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ] || [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  sdlc_die 2 "release authorisation must be given by a human in their own terminal, not from inside a Claude Code session. Open a terminal and run: bash $SDLC_PLUGIN_ROOT/scripts/ship/authorize.sh"
fi
sha=HEAD; ttl=120; by="${USER:-${USERNAME:-human}}"
while [ $# -gt 0 ]; do
  case "$1" in --sha) sha="$2"; shift 2 ;; --ttl-minutes) ttl="$2"; shift 2 ;; --by) by="$2"; shift 2 ;; *) sdlc_die 2 "authorize.sh [--sha <sha|HEAD>] [--ttl-minutes N] [--by <name>]" ;; esac
done
full=$(git -C "$SDLC_PROJECT_DIR" rev-parse --verify "$sha^{commit}" 2>/dev/null) || sdlc_die 1 "unknown commit '$sha'"
art=$(sdlc_artifacts_dir); mkdir -p "$art/release"
now=$(date +%s); expires=$(( now + ttl * 60 ))
f="$art/release/AUTHORIZED-$full"
printf 'authorised_by=%s\nauthorised_at=%s\nexpires=%s\nexpires_at=%s\ncommit=%s\n' "$by" "$(sdlc_iso_now)" "$expires" "$(date -u -r "$expires" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "+${ttl}m")" "$full" >"$f"
echo "ai-sdlc: release of ${full:0:12} authorised by $by for $ttl minutes: $f"
echo "ai-sdlc: production commands matching environments.prod.deployCommandPatterns are now allowed for this commit until it expires."
