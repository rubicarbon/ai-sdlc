#!/usr/bin/env bash
# Stand-in linter for eval cases: fails when the file contains the token LINTFAIL.
f="${1:-}"
if [ -f "$f" ] && grep -q 'LINTFAIL' "$f"; then
  echo "$f:1:1: error: LINTFAIL token present (mock-lint/no-lintfail)"
  exit 1
fi
exit 0
