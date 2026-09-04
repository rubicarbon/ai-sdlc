#!/usr/bin/env bash
# _reports.sh — one implementation of verification-report selection and validation, shared by
# scripts/loop/precondition.sh (ship stage), scripts/ship/preflight.sh and the CI wrapper
# scripts/loop/validate-report.sh. Source after _lib.sh.
#
# Reports live under <artifacts>/verify/ as <date>-<sha>.md (verification) and
# <date>-<sha>-security.md (security review). Every validator here returns 0 when the report
# is acceptable and otherwise prints ONE reason line on stdout and returns 1. Nothing exits,
# so hooks and scripts decide themselves what a failure means. Side channel on every return:
#   SDLC_REPORT_REASON   the reason line (empty when valid)
#   SDLC_REPORT_WARNING  a non-fatal note (security report without a Commit line), also on stderr
#   SDLC_REPORT_CODE     ok | no-file | empty | wrong-kind | no-verdict | many-verdicts |
#                        verdict-fail | no-commit | many-commits | commit-mismatch |
#                        no-blocking | many-blocking | malformed-blocking
#   SDLC_REPORT_COMMIT   the sha captured from the Commit line (may be empty)
#   SDLC_REPORT_BLOCKING the Blocking count of a valid security report
#
# Rules (fail closed: anything the parser cannot read is a red gate, never zero findings):
#   verification  non-empty, not *-security.md, exactly one Verdict line, verdict PASS, exactly
#                 one Commit line whose sha is a prefix of HEAD
#   security      non-empty, exactly one well-formed "Blocking: <n>" line; when a Commit line is
#                 present it must match HEAD (absence is allowed; a warning goes to stderr)

# --- selection ---------------------------------------------------------------------------

sdlc_verify_reports() {     # sdlc_verify_reports <dir> : verification reports, newest first
  # shellcheck disable=SC2010 # ls -t deliberately preserves the report recency ordering.
  ls -t "$1"/*.md 2>/dev/null | grep -v -- '-security\.md$' || true
}
sdlc_latest_verify_report() { sdlc_verify_reports "$1" | head -n1; }

sdlc_security_reports() {   # sdlc_security_reports <dir> : security reports, newest first
  ls -t "$1"/*-security.md 2>/dev/null || true
}
sdlc_latest_security_report() { sdlc_security_reports "$1" | head -n1; }

# --- parsing ---------------------------------------------------------------------------

# sdlc__report_scan <file> : counts and captures over the report lines, matched lowercase.
# Sets SDLC__R_VERDICTS, SDLC__R_VERDICT (pass|fail), SDLC__R_COMMITS, SDLC_REPORT_COMMIT,
# SDLC__R_BLOCK_LINES (lines that start with "Blocking:"), SDLC__R_BLOCK_OK (well-formed ones),
# SDLC__R_BLOCKING (the count of the last well-formed line), SDLC__R_BLOCK_TEXT (last raw line).
sdlc__report_scan() {
  local line l
  local re_verdict='^[[:space:]]*\**verdict(:\**|\**:)[[:space:]]*\**(pass|fail)\**([^a-z0-9]|$)'
  local re_commit='^[[:space:]]*\**commit(:\**|\**:)[[:space:]]*`?([0-9a-f]{7,40})`?([^0-9a-z]|$)'
  local re_block_any='^[[:space:]]*\**blocking\**:'
  local re_block='^[[:space:]]*\**blocking:\**[[:space:]]*([0-9]+)([^0-9]|$)'
  SDLC__R_VERDICTS=0; SDLC__R_VERDICT=""; SDLC__R_COMMITS=0; SDLC_REPORT_COMMIT=""
  SDLC__R_BLOCK_LINES=0; SDLC__R_BLOCK_OK=0; SDLC__R_BLOCKING=""; SDLC__R_BLOCK_TEXT=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"; l="${line,,}"
    if [[ "$l" =~ $re_verdict ]]; then
      SDLC__R_VERDICTS=$((SDLC__R_VERDICTS + 1)); SDLC__R_VERDICT="${BASH_REMATCH[2]}"
    fi
    if [[ "$l" =~ $re_commit ]]; then
      SDLC__R_COMMITS=$((SDLC__R_COMMITS + 1)); SDLC_REPORT_COMMIT="${BASH_REMATCH[2]}"
    fi
    if [[ "$l" =~ $re_block_any ]]; then
      SDLC__R_BLOCK_LINES=$((SDLC__R_BLOCK_LINES + 1)); SDLC__R_BLOCK_TEXT="$line"
      if [[ "$l" =~ $re_block ]]; then
        SDLC__R_BLOCK_OK=$((SDLC__R_BLOCK_OK + 1)); SDLC__R_BLOCKING="${BASH_REMATCH[1]}"
      fi
    fi
  done <"$1"
}

sdlc__report_fail() {  # sdlc__report_fail <code> <reason> : record, print, return 1
  SDLC_REPORT_CODE="$1"; SDLC_REPORT_REASON="$2"; printf '%s\n' "$2"; return 1
}

sdlc__report_basic() {  # shared file checks; prints nothing on success
  local f="$1" name="${1##*/}"
  SDLC_REPORT_CODE=ok; SDLC_REPORT_REASON=""; SDLC_REPORT_WARNING=""
  SDLC_REPORT_COMMIT=""; SDLC_REPORT_BLOCKING=""
  [ -f "$f" ] || { sdlc__report_fail no-file "report $name does not exist"; return 1; }
  [ -s "$f" ] || { sdlc__report_fail empty "report $name is empty"; return 1; }
  return 0
}

# sdlc__commit_matches <captured> <head> : the captured sha is a prefix of (or equals) HEAD
sdlc__commit_matches() {
  local c="${1,,}" h="${2,,}"
  [ -n "$c" ] && [ -n "$h" ] && [ "${h#"$c"}" != "$h" ] || [ "$c" = "$h" ]
}

# --- validation --------------------------------------------------------------------------

# sdlc_validate_verify_report <file> <head_sha>
sdlc_validate_verify_report() {
  local f="$1" head="${2:-}" name="${1##*/}" what
  sdlc__report_basic "$f" || return 1
  what="verification report $name"
  case "$name" in *-security.md)
    sdlc__report_fail wrong-kind "$name is a security report, not a verification report"
    return 1 ;;
  esac
  sdlc__report_scan "$f"
  case "$SDLC__R_VERDICTS" in
    0) sdlc__report_fail no-verdict "$what has no 'Verdict: PASS|FAIL' line"; return 1 ;;
    1) ;;
    *) sdlc__report_fail many-verdicts \
         "$what has $SDLC__R_VERDICTS Verdict lines; exactly one is required"
       return 1 ;;
  esac
  [ "$SDLC__R_VERDICT" = pass ] || { sdlc__report_fail verdict-fail "$what is a FAIL"; return 1; }
  case "$SDLC__R_COMMITS" in
    0) sdlc__report_fail no-commit \
         "$what has no 'Commit: <sha>' line, so it cannot be bound to HEAD"
       return 1 ;;
    1) ;;
    *) sdlc__report_fail many-commits \
         "$what has $SDLC__R_COMMITS Commit lines; exactly one is required"
       return 1 ;;
  esac
  sdlc__commit_matches "$SDLC_REPORT_COMMIT" "$head" || {
    sdlc__report_fail commit-mismatch \
      "$what is for commit ${SDLC_REPORT_COMMIT:0:12}, not HEAD ${head:0:12}: re-verify"
    return 1; }
  SDLC_REPORT_CODE=ok
  return 0
}

# sdlc_validate_security_report <file> [head_sha]
sdlc_validate_security_report() {
  local f="$1" head="${2:-}" name="${1##*/}" what
  sdlc__report_basic "$f" || return 1
  what="security report $name"
  sdlc__report_scan "$f"
  case "$SDLC__R_BLOCK_LINES" in
    0) sdlc__report_fail no-blocking \
         "$what has no 'Blocking: <n>' summary line; refusing to read it as zero findings"
       return 1 ;;
    1) ;;
    *) sdlc__report_fail many-blocking \
         "$what has $SDLC__R_BLOCK_LINES Blocking summary lines; exactly one is required"
       return 1 ;;
  esac
  [ "$SDLC__R_BLOCK_OK" -eq 1 ] || {
    sdlc__report_fail malformed-blocking \
      "$what has a malformed Blocking line ('$SDLC__R_BLOCK_TEXT'); the count must be a number, refusing to read it as zero findings"
    return 1; }
  if [ "$SDLC__R_COMMITS" -gt 1 ]; then
    sdlc__report_fail many-commits "$what has $SDLC__R_COMMITS Commit lines; at most one is allowed"
    return 1
  elif [ "$SDLC__R_COMMITS" -eq 1 ]; then
    if [ -n "$head" ] && ! sdlc__commit_matches "$SDLC_REPORT_COMMIT" "$head"; then
      sdlc__report_fail commit-mismatch \
        "$what is for commit ${SDLC_REPORT_COMMIT:0:12}, not HEAD ${head:0:12}: re-run the security review"
      return 1
    fi
  else
    SDLC_REPORT_WARNING="warning: $what has no Commit line, so it is not bound to HEAD"
    echo "ai-sdlc: $SDLC_REPORT_WARNING" >&2
  fi
  SDLC_REPORT_BLOCKING="$SDLC__R_BLOCKING"; export SDLC_REPORT_BLOCKING
  SDLC_REPORT_CODE=ok
  return 0
}

# --- policy ------------------------------------------------------------------------------

# sdlc_select_verify_report <dir> <head_sha> : the verification report that decides the ship
# stage. Walks the reports newest first; the newest one bound to HEAD decides (a valid PASS
# prints its path and returns 0, anything else prints its reason and returns 1). Reports for
# another commit are skipped, so a stale report never blocks and never passes; when no report
# is bound to HEAD the newest report's reason (or "no report") is printed and 1 returned.
sdlc_select_verify_report() {
  local dir="$1" head="${2:-}" r first=""
  local -a reports=()
  while IFS= read -r r; do [ -n "$r" ] && reports+=("$r"); done < <(sdlc_verify_reports "$dir")
  if [ ${#reports[@]} -eq 0 ]; then
    SDLC_REPORT_CODE=no-file
    SDLC_REPORT_REASON="no verification report under $dir/: run /ai-sdlc:sdlc-verify"
    printf '%s\n' "$SDLC_REPORT_REASON"
    return 1
  fi
  for r in "${reports[@]}"; do
    # a redirected function call keeps the side channel (no subshell is involved)
    if sdlc_validate_verify_report "$r" "$head" >/dev/null; then printf '%s\n' "$r"; return 0; fi
    [ -n "$first" ] || first="$SDLC_REPORT_REASON"
    [ "$SDLC_REPORT_CODE" = commit-mismatch ] && continue
    printf '%s\n' "$SDLC_REPORT_REASON"; return 1
  done
  SDLC_REPORT_REASON="$first"
  printf '%s\n' "$first"; return 1
}
