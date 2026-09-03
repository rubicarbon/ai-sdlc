#!/usr/bin/env bash
# gate-production.sh (PreToolUse: Bash|PowerShell)
# Production-affecting commands (environments.prod.deployCommandPatterns) run only with an
# explicit, fresh release authorisation: <artifacts>/release/AUTHORIZED-<HEAD sha> written by
# /ai-sdlc:sdlc-ship after a human said yes. The marker carries an expiry; after it, or on a
# different commit, the gate closes again. Agents hold no production credentials, and this hook
# is the last deterministic stop before a deploy command leaves the session.
set -u
. "${0%/*}/../scripts/_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_hook.sh"

[ -n "$HOOK_CMD" ] || exit 0
defaults=("git push * main" "git push * master" "git push * release/*" "git push * production" "git push --tags*" "gh workflow run *deploy*" "gh release create *" "az pipelines run *" "az pipelines release *" "az webapp deploy*" "az functionapp deploy*" "az containerapp up*" "kubectl apply *" "kubectl rollout *" "helm upgrade *" "helm install *" "terraform apply *" "pulumi up *" "aws cloudformation deploy *" "aws lambda update-function-code *" "serverless deploy*" "sls deploy*" "fly deploy*" "vercel --prod*" "netlify deploy --prod*" "cap production deploy*" "docker push *")
mapfile -t patterns < <(hook_list '.environments.prod.deployCommandPatterns' "${defaults[@]}")

glob_to_re() {  # command glob -> anchored ERE; * matches anything including spaces
  local g="$1" out="" i c
  for (( i=0; i<${#g}; i++ )); do
    c="${g:$i:1}"
    case "$c" in '*') out="$out.*" ;; '.'|'+'|'('|')'|'|'|'^'|'$'|'{'|'}'|'['|']'|'\\'|'?') out="$out\\$c" ;; *) out="$out$c" ;; esac
  done
  printf '(^|[;&|]|&&|\\|\\||\\n)[[:space:]]*%s[[:space:]]*($|[;&|])' "$out"
}

matched=""
for p in "${patterns[@]}"; do
  [ -n "$p" ] || continue
  re=$(glob_to_re "$p")
  if [[ "$HOOK_CMD" =~ $re ]]; then matched="$p"; break; fi
done
[ -n "$matched" ] || exit 0

sha=$(git -C "$HOOK_PROJECT" rev-parse HEAD 2>/dev/null || echo unknown)
marker="$HOOK_ARTIFACTS/release/AUTHORIZED-$sha"
rel_marker=$(hook_rel "$marker")
if [ ! -f "$marker" ]; then
  hook_deny "'$HOOK_CMD' matches the production pattern '$matched' and there is no release authorisation for commit ${sha:0:12}. Run /ai-sdlc:sdlc-ship: a human must authorise the release, which writes $rel_marker."
fi
expires=$(sed -n 's/^expires=//p' "$marker" | head -n1)
now=$(date +%s)
if [ -n "$expires" ] && [ "$now" -gt "$expires" ] 2>/dev/null; then
  hook_deny "release authorisation $rel_marker expired $(( (now - expires) / 60 )) minutes ago. Ask the human to re-authorise through /ai-sdlc:sdlc-ship."
fi
exit 0
