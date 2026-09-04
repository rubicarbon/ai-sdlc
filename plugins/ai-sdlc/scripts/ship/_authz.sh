#!/usr/bin/env bash
# _authz.sh — validation of a release authorisation marker, shared by hooks/gate-production.sh
# and scripts/ship/preflight.sh. Source after _lib.sh.
#
# A marker is <artifacts>/release/AUTHORIZED-<full sha>, written by scripts/ship/authorize.sh
# from a human's own terminal, with these lines, each exactly once:
#   authorised_by=<identity>        non-empty
#   authorised_at=<iso timestamp>   non-empty
#   expires=<epoch seconds>         digits only, strictly in the future
#   expires_at=<iso timestamp>      informational (not validated)
#   commit=<40 hex>                 equal to HEAD and to the sha in the file name
#
# sdlc_check_authorization <file> <head_sha> : returns 0 when the marker is valid, otherwise
# prints ONE reason line on stdout and returns 1. Never exits, never converts a broken marker
# into a valid one: anything the parser cannot read closes the gate.

sdlc__authz_fail() { printf '%s\n' "$1"; return 1; }

sdlc__authz_count() {  # sdlc__authz_count <marker name> <key> <n> : exactly one line per key
  [ "$3" -ne 0 ] || { sdlc__authz_fail "release authorisation $1 has no $2= line"; return 1; }
  [ "$3" -eq 1 ] || {
    sdlc__authz_fail "release authorisation $1 has $3 $2= lines; exactly one is required"
    return 1; }
}

sdlc_check_authorization() {
  local f="$1" head="${2,,}" name="${1##*/}" line key val now
  local by="" at="" exp="" commit="" n_by=0 n_at=0 n_exp=0 n_commit=0
  [ -f "$f" ] || {
    sdlc__authz_fail "no release authorisation for commit ${head:0:12}: $name does not exist"
    return 1; }
  [ -s "$f" ] || { sdlc__authz_fail "release authorisation $name is empty"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      authorised_by) n_by=$((n_by + 1)); by="$val" ;;
      authorised_at) n_at=$((n_at + 1)); at="$val" ;;
      expires)       n_exp=$((n_exp + 1)); exp="$val" ;;
      commit)        n_commit=$((n_commit + 1)); commit="$val" ;;
    esac
  done <"$f"

  # the expiry is judged first because "expired" is the reason a human most often needs
  sdlc__authz_count "$name" expires "$n_exp" || return 1
  case "$exp" in ''|*[!0-9]*)
    sdlc__authz_fail "release authorisation $name has a non-numeric expires= value ('$exp')"
    return 1 ;;
  esac
  printf -v now '%(%s)T' -1 2>/dev/null || now=$(date +%s)
  if [ "$exp" -le "$now" ]; then
    sdlc__authz_fail "release authorisation $name expired $(( (now - exp) / 60 )) minutes ago"
    return 1
  fi

  sdlc__authz_count "$name" commit "$n_commit" || return 1
  sdlc__authz_count "$name" authorised_by "$n_by" || return 1
  sdlc__authz_count "$name" authorised_at "$n_at" || return 1
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || {
    sdlc__authz_fail "release authorisation $name has a malformed commit= value ('$commit'); a full 40-hex sha is required"
    return 1; }
  case "$name" in AUTHORIZED-*) ;; *)
    sdlc__authz_fail "release authorisation $name is not named AUTHORIZED-<sha>"; return 1 ;;
  esac
  [ "${name#AUTHORIZED-}" = "$commit" ] || {
    sdlc__authz_fail "release authorisation $name names commit ${name#AUTHORIZED-} but its commit= line says ${commit:0:12}"
    return 1; }
  [ "$commit" = "$head" ] || {
    sdlc__authz_fail "release authorisation $name is for commit ${commit:0:12}, not HEAD ${head:0:12}"
    return 1; }
  [ -n "${by//[[:space:]]/}" ] || {
    sdlc__authz_fail "release authorisation $name has an empty authorised_by= identity"; return 1; }
  [ -n "${at//[[:space:]]/}" ] || {
    sdlc__authz_fail "release authorisation $name has an empty authorised_at= timestamp"; return 1; }
  return 0
}
