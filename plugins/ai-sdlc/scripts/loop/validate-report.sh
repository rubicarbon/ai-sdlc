#!/usr/bin/env bash
# validate-report.sh — validate one saved report with the same rules the ship gates apply.
#
#   validate-report.sh <file> [--security] [--head <sha>]
#
# Exit 0 when the report is valid (one summary line on stdout), 1 otherwise with the reason on
# stderr, 2 on usage errors. Without --head the HEAD of the repository containing the file is
# used; a verification report cannot be validated without a HEAD to bind it to, a security
# report can (its Commit line is then only checked for shape). A verification PASS also needs
# one "Tree: clean" or "Tree: isolated" line saying the verified tree was HEAD. Read-only: safe
# for CI and for the verifier subagent. Works outside an sdlc project too.
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
. "$SDLC_PLUGIN_ROOT/scripts/loop/_reports.sh"

usage() { sdlc_die 2 "validate-report.sh <file> [--security] [--head <sha>]"; }
file=""; security=0; head=""
while [ $# -gt 0 ]; do
  case "$1" in
    --security) security=1; shift ;;
    --head) [ -n "${2:-}" ] || usage; head="$2"; shift 2 ;;
    -*) usage ;;
    *) [ -z "$file" ] || usage; file="$1"; shift ;;
  esac
done
[ -n "$file" ] || usage

if [ -z "$head" ]; then
  dir="${file%/*}"; [ "$dir" = "$file" ] && dir="."
  head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)
fi

# The validators print their reason on stdout and keep details in SDLC_REPORT_*; they are
# called without a subshell (stdout to /dev/null, warnings pass through on stderr) so that
# side channel survives, and the reason is re-emitted on stderr for CI logs.
if [ $security = 1 ]; then
  if sdlc_validate_security_report "$file" "$head" >/dev/null; then
    echo "valid security report: ${file##*/} (Blocking: $SDLC_REPORT_BLOCKING)"; exit 0
  fi
else
  if [ -z "$head" ]; then
    sdlc_die 1 "cannot determine HEAD for ${file##*/}: pass --head <sha>"
  fi
  if sdlc_validate_verify_report "$file" "$head" >/dev/null; then
    echo "valid verification report: ${file##*/} (PASS for commit ${head:0:12}, tree $SDLC_REPORT_TREE)"; exit 0
  fi
fi
echo "ai-sdlc: $SDLC_REPORT_REASON" >&2
exit 1
