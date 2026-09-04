#!/usr/bin/env bash
# azure-review.sh — run the ai-sdlc pull-request review with Claude Code inside an Azure
# pipeline and fail closed. The pipeline template (templates/azure/pipelines/sdlc-pr-review.yml)
# calls it as the review step, without "|| true", so the job fails whenever the review did
# not complete.
#
#   azure-review.sh --base <branch> [--max-turns N] [--max-budget-usd X]
#                   [--out review.md] [--result claude-result.json]
#                   [--status review-status.txt] [--allowed-tools LIST] [--print-prompt]
#
# Success (exit 0, status file "ok") requires every one of these:
#   - `claude` (resolved from PATH) exits 0
#   - the result file parses as JSON with .is_error false and .subtype "success"
#   - the review file exists, is non-empty, and holds exactly one line "Blocking: <n>"
# Anything else, including an exhausted cap (subtype error_max_turns / error_max_budget_usd)
# or a missing report, replaces the review file with a clearly labelled diagnostic
# ("# ai-sdlc review FAILED (no review result)" plus the reason), writes status "failed",
# and exits 1. The diagnostic never looks like a completed review, so a policy that reads
# the comment cannot mistake it for one.
#
# The prompt is built with printf '%s' substitution, never sed, so a base branch such as
# release/2026.09, feat/a&b or "release candidate" reaches the prompt literally.
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"

base=""; max_turns=40; max_budget=5; out=review.md; result=claude-result.json
status=review-status.txt; allowed=""; print_prompt=0
usage() {
  sdlc_die 2 "azure-review.sh --base <branch> [--max-turns N] [--max-budget-usd X] [--out FILE] [--result FILE] [--status FILE] [--allowed-tools LIST] [--print-prompt]"
}
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="${2:-}"; shift 2 ;;
    --max-turns) max_turns="${2:-}"; shift 2 ;;
    --max-budget-usd) max_budget="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    --result) result="${2:-}"; shift 2 ;;
    --status) status="${2:-}"; shift 2 ;;
    --allowed-tools) allowed="${2:-}"; shift 2 ;;
    --print-prompt) print_prompt=1; shift ;;
    *) usage ;;
  esac
done
[ -n "$base" ] || usage
case "$max_turns" in ''|*[!0-9]*) sdlc_die 2 "azure-review.sh: --max-turns must be an integer (got '$max_turns')" ;; esac
case "$max_budget" in ''|*[!0-9.]*) sdlc_die 2 "azure-review.sh: --max-budget-usd must be a number (got '$max_budget')" ;; esac
[ -n "$out" ] && [ -n "$result" ] && [ -n "$status" ] || usage
[ -n "$allowed" ] || allowed="Read,Grep,Glob,Write($out),Bash(git diff *),Bash(git log *),Bash(git show *)"

# The only printf directives in the format are the two %s below (base branch, report file).
prompt_fmt='You are reviewing a pull request in a repository that runs the ai-sdlc loop.
1. Load the skill ai-sdlc:sdlc-security-review and read REVIEW.md. Audit `git diff origin/%s...HEAD` with the check list; rank Blocking / Important / Nit; respect the nit cap.
2. Find the ticket id (AB#n) in the PR title or body; if the spec or ticket is in .sdlc/features/ or .scratch/, list requirements that are missing, partial, or not asked for.
3. Write the full review to the file %s in the sdlc-security-review report format (its summary line "Blocking: <n>  Important: <n>  Nit: <n> (cap <cap>)" must appear exactly once), followed by a "Spec compliance" section, ending with: "Advisory review by ai-sdlc; a human required reviewer approves."
Do not edit any other file.'
# shellcheck disable=SC2059
prompt=$(printf "$prompt_fmt" "$base" "$out")
if [ $print_prompt = 1 ]; then printf '%s\n' "$prompt"; exit 0; fi

write_status() { printf '%s\n' "$1" >"$status"; }

fail() {  # fail <reason>: diagnostic instead of a review, status failed, exit 1
  local reason="$1"
  {
    printf '# ai-sdlc review FAILED (no review result)\n\n'
    printf 'The pull request was NOT reviewed. Reason: %s\n\n' "$reason"
    printf 'Base branch: %s. Caps: --max-turns %s, --max-budget-usd %s.\n\n' "$base" "$max_turns" "$max_budget"
    printf '%s\n' "This is a pipeline failure, not a review verdict. The review step exits 1 so the build policy cannot treat a missing review as a pass. Re-run the pipeline; when the caps were exhausted, raise cost.maxTurns / cost.maxBudgetUsd in sdlc.config.json or split the pull request."
  } >"$out"
  write_status failed
  echo "ai-sdlc: review FAILED: $reason" >&2
  exit 1
}

# Stale files from an earlier step must never pass as this run's result.
rm -f "$out" "$result"
write_status failed

claude_bin=$(command -v claude 2>/dev/null) || fail "the 'claude' command is not on PATH (the install step did not run or failed)"
errf=$(sdlc_tmpfile .err)
"$claude_bin" -p "$prompt" --output-format json \
  --max-turns "$max_turns" --max-budget-usd "$max_budget" \
  --allowedTools "$allowed" >"$result" 2>"$errf"
rc=$?
first_err=$(head -n1 "$errf" 2>/dev/null || true); rm -f "$errf"
[ $rc -eq 0 ] || fail "claude exited with status $rc${first_err:+: $first_err}"

[ -s "$result" ] || fail "claude wrote no result JSON to $result"
# --output-format json prints one result object; a JSON array (stream) is accepted by taking
# its last result entry. Anything else is not a result.
entry=$(jq -c 'if type == "array" then ([.[] | select(.type == "result")] | last) else . end' "$result" 2>/dev/null) \
  || fail "$result is not valid JSON"
[ -n "$entry" ] && [ "$entry" != null ] || fail "$result holds no result entry"
subtype=$(printf '%s' "$entry" | jq -r 'if .subtype == null then "missing" else (.subtype | tostring) end')
is_error=$(printf '%s' "$entry" | jq -r 'if .is_error == null then "missing" else (.is_error | tostring) end')
if [ "$is_error" != false ] || [ "$subtype" != success ]; then
  case "$subtype" in
    error_max_turns) fail "the turn cap was exhausted (subtype $subtype, --max-turns $max_turns) before a review was produced" ;;
    error_max_budget_usd) fail "the budget cap was exhausted (subtype $subtype, --max-budget-usd $max_budget USD) before a review was produced" ;;
    *) fail "claude reported subtype '$subtype' with is_error '$is_error' (expected subtype success and is_error false)" ;;
  esac
fi

[ -f "$out" ] || fail "claude finished without writing the review file $out"
[ -s "$out" ] || fail "the review file $out is empty"
n_blocking=$(grep -cE '^Blocking:[[:space:]]*[0-9]+' "$out" || true)
[ "$n_blocking" = 1 ] || fail "the review file $out must contain exactly one 'Blocking: <n>' summary line, found ${n_blocking:-0}"

write_status ok
cost=$(printf '%s' "$entry" | jq -r '.total_cost_usd // 0'); turns=$(printf '%s' "$entry" | jq -r '.num_turns // 0')
echo "ai-sdlc: review ok: $out written against origin/$base ($turns turns, $cost USD)" >&2
exit 0
