#!/usr/bin/env bash
# gate-production.sh (PreToolUse: Bash|PowerShell)
# Commands matching environments.prod.deployCommandPatterns run only with an explicit, fresh
# release authorisation: <artifacts>/release/AUTHORIZED-<HEAD sha> written by
# /ai-sdlc:sdlc-ship after a human said yes. The marker carries an expiry; after it, or on a
# different commit, the gate closes again. The pattern list comes from the project's own
# sdlc.config.json only (/ai-sdlc:sdlc-init seeds a push to the default branch and the configured
# production deploy command); there are no built-in patterns, so an absent or empty list gates
# nothing. Agents hold no production credentials, and this hook is the last deterministic stop
# before a configured deploy command leaves the session.
set -u
. "${0%/*}/../scripts/_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_hook.sh"

[ -n "$HOOK_CMD" ] || exit 0
mapfile -t patterns < <(hook_list '.environments.prod.deployCommandPatterns')
[ ${#patterns[@]} -gt 0 ] || exit 0

glob_to_re() {  # command glob -> anchored ERE; * matches anything including spaces
  # The command must start and end at a shell separator (;, &, |, newline) or at the ends of the
  # string, so a pattern cannot match mid-word. A literal newline goes into the bracket
  # expressions: POSIX ERE has no "\n" escape (bracket expressions take "\" literally, and bash's
  # [[ =~ ]] rejects the bare escape on msys), so writing it as text silently disabled the whole
  # gate on Git Bash. "&&" and "||" need no alternation of their own; their second character is in
  # the bracket already.
  local g="$1" out="" i c nl=$'\n'
  for (( i=0; i<${#g}; i++ )); do
    c="${g:$i:1}"
    case "$c" in '*') out="$out.*" ;; '.'|'+'|'('|')'|'|'|'^'|'$'|'{'|'}'|'['|']'|'\\'|'?') out="$out\\$c" ;; *) out="$out$c" ;; esac
  done
  printf '(^|[;&|%s])[[:space:]]*%s[[:space:]]*($|[;&|%s])' "$nl" "$out" "$nl"
}

matched=""
for p in "${patterns[@]}"; do
  [ -n "$p" ] || continue
  re=$(glob_to_re "$p")
  if [[ "$HOOK_CMD" =~ $re ]]; then matched="$p"; break; fi
done
[ -n "$matched" ] || exit 0

# The marker is validated by scripts/ship/_authz.sh, the same rules preflight.sh applies: every
# field present exactly once, a numeric expiry in the future, and a full sha equal to HEAD and
# to the file name. Anything the validator cannot read denies.
. "$SDLC_PLUGIN_ROOT/scripts/ship/_authz.sh"
sha=$(git -C "$HOOK_PROJECT" rev-parse HEAD 2>/dev/null || echo unknown)
marker="$HOOK_ARTIFACTS/release/AUTHORIZED-$sha"
rel_marker=$(hook_rel "$marker")
if [ ! -f "$marker" ]; then
  hook_deny "'$HOOK_CMD' matches the production pattern '$matched' and there is no release authorisation for commit ${sha:0:12}. Run /ai-sdlc:sdlc-ship: a human must authorise the release, which writes $rel_marker."
fi
if ! reason=$(sdlc_check_authorization "$marker" "$sha"); then
  hook_deny "'$HOOK_CMD' matches the production pattern '$matched' and $reason ($rel_marker). Ask the human to re-authorise through /ai-sdlc:sdlc-ship."
fi
exit 0
