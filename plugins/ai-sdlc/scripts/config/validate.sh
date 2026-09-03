#!/usr/bin/env bash
# validate.sh — check sdlc.config.json against the schema with jq alone.
#
#   validate.sh [config.json] [--schema schema.json] [--quiet]
#
# Exit 0 valid, 1 invalid (errors on stderr, one per line), 2 usage/IO error.
# The schema bundled with the plugin is the default; the copy at the marketplace root
# (sdlc.config.schema.json) exists for editors that follow the "$schema" URL.
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"

cfg=""; schema="$SDLC_PLUGIN_ROOT/config/sdlc.config.schema.json"; quiet=0
while [ $# -gt 0 ]; do
  case "$1" in
    --schema) schema="$2"; shift 2 ;;
    --quiet) quiet=1; shift ;;
    -*) sdlc_die 2 "validate.sh [config.json] [--schema schema.json] [--quiet]" ;;
    *) cfg="$1"; shift ;;
  esac
done
if [ -z "$cfg" ]; then
  SDLC_PROJECT_OPTIONAL=1 . "$SDLC_PLUGIN_ROOT/scripts/_project.sh"
  cfg="${SDLC_CONFIG:-sdlc.config.json}"
fi
[ -f "$cfg" ] || sdlc_die 2 "validate.sh: no such file: $cfg"
[ -f "$schema" ] || sdlc_die 2 "validate.sh: no such schema: $schema"
jq -e . "$cfg" >/dev/null 2>&1 || { echo "$cfg: not valid JSON" >&2; exit 1; }

errors=$(jq -n -r --slurpfile schema "$schema" --slurpfile doc "$cfg" -f "$SDLC_PLUGIN_ROOT/scripts/config/schema-check.jq") || sdlc_die 2 "validate.sh: schema check failed to run"
if [ -n "$errors" ]; then
  printf '%s\n' "$errors" | sed "s|^|$cfg: |" >&2
  exit 1
fi
[ $quiet = 1 ] || echo "$cfg: valid"
exit 0
