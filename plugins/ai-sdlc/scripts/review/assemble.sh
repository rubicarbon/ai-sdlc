#!/usr/bin/env bash
# assemble.sh — one review report from the security auditor's output and the spec-compliance
# findings, with a single summary line that counts both.
#
#   assemble.sh --security <auditor-report> --spec <spec-findings> --head <sha> --base <sha> \
#               --pr <id|local> --cap <nit cap> --out <file> [--title <text>]
#
# The auditor writes the sdlc-security-review format (its own title, Commit and summary lines);
# those lines are dropped here and the ranked sections (## Blocking, ## Important, ## Nit and
# whatever follows) are kept verbatim. The spec file holds "## Missing", "## Partial" and
# "## Not asked for" sections with one bullet per finding, or "## No spec found". Missing
# requirements count as Blocking, partial ones and unrequested work as Important; nits stay the
# auditor's. The result has exactly one "Blocking: <n>  Important: <n>  Nit: <n> (cap <c>)" line,
# one "**Commit:**" line and ends with the advisory sentence, so scripts/loop/validate-report.sh
# --security --head <sha> accepts it. Exit 1 when the auditor report has no ranked section (the
# audit did not happen), 2 on usage errors.
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
usage() { sdlc_die 2 "assemble.sh --security <file> --spec <file> --head <sha> --base <sha> --pr <id|local> --cap <n> --out <file> [--title <text>]"; }
sec=""; spec=""; head=""; base=""; pr=""; cap=5; out=""; title=""
while [ $# -gt 0 ]; do
  case "$1" in
    --security) sec="${2:-}"; shift 2 ;; --spec) spec="${2:-}"; shift 2 ;;
    --head) head="${2:-}"; shift 2 ;; --base) base="${2:-}"; shift 2 ;;
    --pr) pr="${2:-}"; shift 2 ;; --cap) cap="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;; --title) title="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$sec" ] && [ -n "$head" ] && [ -n "$base" ] && [ -n "$pr" ] && [ -n "$out" ] || usage
[ -f "$sec" ] || sdlc_die 2 "assemble.sh: auditor report $sec does not exist"
case "$cap" in ''|*[!0-9]*) sdlc_die 2 "assemble.sh: --cap must be a number" ;; esac

# count_bullets <file> <section heading regex> -> number of "- " bullets under that ## heading
# (until the next ## heading); "- none" and "- (none)" do not count.
count_bullets() {
  local f="$1" re="$2" in=0 n=0 line l
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"; l="${line,,}"
    if [[ "$l" =~ ^##[[:space:]] ]]; then
      if [[ "$l" =~ ^##[[:space:]]+$re ]]; then in=1; else in=0; fi; continue
    fi
    if [ $in = 1 ] && [[ "$l" =~ ^[[:space:]]*-[[:space:]] ]] && ! [[ "$l" =~ ^[[:space:]]*-[[:space:]]+\(?none ]]; then n=$((n+1)); fi
  done <"$f"
  printf '%s' "$n"
}
grep -qiE '^##[[:space:]]+(blocking|important|nit)' "$sec" || sdlc_die 1 "assemble.sh: $sec has no ranked section (## Blocking / ## Important / ## Nit); the audit did not produce a report"

sb=$(count_bullets "$sec" 'blocking'); si=$(count_bullets "$sec" 'important'); sn=$(count_bullets "$sec" 'nits?')
pm=0; pp=0; pn=0; spec_body=""
if [ -n "$spec" ] && [ -f "$spec" ]; then
  pm=$(count_bullets "$spec" 'missing'); pp=$(count_bullets "$spec" 'partial'); pn=$(count_bullets "$spec" 'not[[:space:]]+asked')
  spec_body=$(sed 's/\r$//' "$spec")
else
  spec_body=$'## No spec found\n\nNo specification or ticket was located for this change; requirements were not checked (this is a gap, not a pass).'
fi
blocking=$(( sb + pm )); important=$(( si + pp + pn )); nit="$sn"

# the auditor's body without its title, Commit line, summary line and closing advisory sentence
body=$(awk '
  BEGIN { started = 0 }
  {
    line = $0; sub(/\r$/, "", line); l = tolower(line)
    if (!started) { if (l ~ /^##[[:space:]]/) started = 1; else next }
    if (l ~ /^[[:space:]]*\**commit(:\**|\**:)/) next
    if (l ~ /^[[:space:]]*\**blocking\**:/) next
    if (l ~ /^[[:space:]]*\**status(:\**|\**:)/) next
    if (l ~ /advisory/ && l ~ /approve/) next
    print line
  }' "$sec")

[ -n "$title" ] || title="PR $pr"
[ "$pr" = local ] && title="${title/PR local/local change}"
mkdir -p "$(dirname "$out")" || sdlc_die 1 "assemble.sh: cannot create $(dirname "$out")"
{
  printf '# Security review: %s against %s\n' "$title" "${base:0:12}"
  printf '**Commit:** %s  **Base:** %s\n\n' "$head" "$base"
  printf 'Blocking: %s  Important: %s  Nit: %s (cap %s)\n\n' "$blocking" "$important" "$nit" "$cap"
  printf '%s\n\n' "$body"
  printf '## Spec compliance\n\n'
  printf 'Ranked into the totals above: a missing requirement is Blocking, a partial one and work that was not asked for are Important.\n\n'
  printf '%s\n\n' "$spec_body"
  printf 'Advisory review by ai-sdlc; a human code owner approves.\n'
} >"$out"
jq -cn --arg o "$out" --argjson b "$blocking" --argjson i "$important" --argjson n "$nit" \
  --argjson sb "$sb" --argjson pm "$pm" '{out:$o, blocking:$b, important:$i, nit:$n, security_blocking:$sb, spec_missing:$pm}'
