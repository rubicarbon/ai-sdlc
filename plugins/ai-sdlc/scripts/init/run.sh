#!/usr/bin/env bash
# run.sh — the deterministic engine behind /sdlc-init, /sdlc-status and /sdlc-upgrade.
#
#   run.sh [--repo-dir DIR] [--platform github|azure|both|none] [--tier 0-3] [--team solo|team]
#          [--verify CMD] [--format CMD] [--lint CMD] [--envs dev,staging,prod]
#          [--owner O --name N] [--azure-org URL --azure-project P --azure-repo R]
#          [--max-turns N --max-budget-usd X --alert-threshold-usd Y]
#          [--deploy-staging CMD --deploy-production CMD | --no-deploy]
#          [--yes] [--force] [--upgrade] [--only <path>]... [--check] [--dry-run]
#
# First run: builds sdlc.config.json from detect.sh plus flags, validates it against the schema,
# renders the files for the chosen tier and platform, merges permission rules into
# .claude/settings.json, and prints next steps. Every rendered file is recorded in
# <artifacts>/managed-files.json with the hash of what was written, so later runs can tell
# "unchanged", "template-changed" (plugin updated) and "user-edited" apart:
#   - re-run with nothing to do prints "already initialised"
#   - --check writes nothing and exits 1 when anything drifted (CI)
#   - --upgrade re-renders template-changed files; user-edited files need --force
#   - user-edited files are never overwritten without --force
#   - the recorded hash moves only when the rendered content was installed, upgraded,
#     overwritten, or already equals the file; template-changed and user-edited keep the
#     previous record, so a reported template change stays "template-changed" run after run
#   - --only <path> limits --upgrade / --force and the creation of missing files to the paths
#     listed; other missing files are reported "missing" and left alone
#   - --dry-run and --check never touch the tree (not even the artifacts directories)
# Artifact directories (<artifacts>/features, verify, releases, postmortems, metrics/cost and
# docs/adr) get one status entry each from tier 1: unchanged (exists), missing (absent under
# --check / --dry-run) or installed (created with a .gitkeep placeholder; a directory without
# .gitkeep is fine).
# Deploy automation (tier 3, platform other than none): the deploy workflow runs
# commands.deployStaging / commands.deployProduction from sdlc.config.json with SDLC_ENVIRONMENT
# and SDLC_SHA exported. On init or a re-tier both commands are required (--deploy-staging,
# --deploy-production) unless --no-deploy skips the deploy template; a plain re-run without
# them skips the template and says so in next_steps. The production command (exact string and
# "<command>*") is always added to environments.prod.deployCommandPatterns so the
# gate-production hook covers it.
# Output: one JSON summary on stdout; human-readable notes on stderr.
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
T="$SDLC_PLUGIN_ROOT/templates"
RENDER="$SDLC_PLUGIN_ROOT/scripts/init/render.sh"

dir="$PWD"; platform=""; tier=""; team=""; verify=""; format_cmd=""; lint_cmd=""; envs="dev,staging,prod"
owner=""; name=""; az_org=""; az_project=""; az_repo=""; max_turns=""; max_budget=""; alert=""
deploy_staging=""; deploy_production=""; no_deploy=0
yes=0; force=0; upgrade=0; check=0; dry=0; only=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo-dir) dir="$2"; shift 2 ;;
    --only) only+=("${2//\\//}"); shift 2 ;;
    --deploy-staging) deploy_staging="$2"; shift 2 ;;
    --deploy-production) deploy_production="$2"; shift 2 ;;
    --no-deploy) no_deploy=1; shift ;;
    --platform) platform="$2"; shift 2 ;;
    --tier) tier="$2"; shift 2 ;;
    --team) team="$2"; shift 2 ;;
    --verify) verify="$2"; shift 2 ;;
    --format) format_cmd="$2"; shift 2 ;;
    --lint) lint_cmd="$2"; shift 2 ;;
    --envs) envs="$2"; shift 2 ;;
    --owner) owner="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --azure-org) az_org="$2"; shift 2 ;;
    --azure-project) az_project="$2"; shift 2 ;;
    --azure-repo) az_repo="$2"; shift 2 ;;
    --max-turns) max_turns="$2"; shift 2 ;;
    --max-budget-usd) max_budget="$2"; shift 2 ;;
    --alert-threshold-usd) alert="$2"; shift 2 ;;
    --yes|--non-interactive) yes=1; shift ;;
    --force) force=1; shift ;;
    --upgrade) upgrade=1; shift ;;
    --check) check=1; shift ;;
    --dry-run) dry=1; shift ;;
    *) sdlc_die 2 "run.sh: unknown option $1 (see the header of scripts/init/run.sh)" ;;
  esac
done
case "${tier:-0}" in 0|1|2|3) ;; *) sdlc_die 2 "run.sh: --tier must be 0, 1, 2 or 3 (got '$tier')" ;; esac
case "${platform:-github}" in github|azure|both|none) ;; *) sdlc_die 2 "run.sh: --platform must be github, azure, both or none (got '$platform')" ;; esac
cd "$dir" 2>/dev/null || sdlc_die 1 "run.sh: cannot cd to $dir"
dir=$(pwd -P)
{ [ -d .git ] || [ -f .git ]; } || sdlc_die 1 "run.sh: $dir is not the root of a git repository (run git init there first)"
note() { echo "ai-sdlc: $*" >&2; }

# ------------------------------------------------------------------ config
detected=$(bash "$SDLC_PLUGIN_ROOT/scripts/init/detect.sh" --repo-dir "$dir") || sdlc_die 1 "detect.sh failed"
mode=init
if [ -f sdlc.config.json ]; then
  mode=rerun
  bash "$SDLC_PLUGIN_ROOT/scripts/config/validate.sh" sdlc.config.json --quiet || sdlc_die 1 "existing sdlc.config.json is invalid; fix it before re-running"
  config=$(<sdlc.config.json)
  [ -n "$platform" ] && [ "$platform" != "$(jq -r .platform <<<"$config")" ] && note "ignoring --platform: sdlc.config.json already says $(jq -r .platform <<<"$config") (edit the file to change it)"
  [ -n "$tier" ] && [ "$tier" != "$(jq -r .tier <<<"$config")" ] && { config=$(jq -c --argjson t "$tier" '.tier=$t | .guardrails.requireTicket = ($t >= 2)' <<<"$config"); mode=retier; note "tier changed to $tier (guardrails.requireTicket follows the tier)"; }
else
  [ -n "$platform" ] || platform=$(jq -r .platform <<<"$detected")
  [ -n "$tier" ] || tier=0
  [ -n "$team" ] || team=solo
  [ -n "$verify" ] || verify=$(jq -r '.verifyCandidates[0]' <<<"$detected")
  [ -n "$owner" ] || owner=$(jq -r '.repo.owner' <<<"$detected")
  [ -n "$name" ] || name=$(jq -r '.repo.name' <<<"$detected"); [ -n "$name" ] || name="${dir##*/}"
  [ -n "$az_org" ] || az_org=$(jq -r '.azure.organization' <<<"$detected")
  [ -n "$az_project" ] || az_project=$(jq -r '.azure.project' <<<"$detected")
  [ -n "$az_repo" ] || az_repo=$(jq -r '.azure.repo' <<<"$detected")
  case "$platform" in github|azure|both|none) ;; *) sdlc_die 2 "run.sh: --platform must be github, azure, both or none (got '$platform')" ;; esac
  case "$tier" in 0|1|2|3) ;; *) sdlc_die 2 "run.sh: --tier must be 0, 1, 2 or 3" ;; esac
  case "$team" in solo|team) ;; *) sdlc_die 2 "run.sh: --team must be solo or team" ;; esac
  if [ "$platform" = azure ] || [ "$platform" = both ]; then
    [ -n "$az_org" ] && [ -n "$az_project" ] && [ -n "$az_repo" ] || sdlc_die 2 "run.sh: Azure DevOps needs --azure-org https://dev.azure.com/<org> --azure-project <project> --azure-repo <repo> (not derivable from the remote)"
  fi
  reuse=$(jq -r 'if .mattpocock.installed then "plugin" elif (.mattpocock.editable_copies|length)>0 then "editable" else "absent" end' <<<"$detected")
  mp_ver=$(jq -r '.mattpocock.installed_version // empty' <<<"$detected")
  IFS=',' read -ra env_list <<<"$envs"
  env_json='{}'
  for e in "${env_list[@]}"; do
    e="${e// /}"; [ -n "$e" ] || continue
    case "$e" in
      prod|production)
        case "$platform" in github) cli_pat='["gh workflow run *deploy*","gh release create *"]' ;; azure) cli_pat='["az pipelines run *","az pipelines release *"]' ;; *) cli_pat='["gh workflow run *deploy*","az pipelines run *"]' ;; esac
        env_json=$(jq -c --arg e "$e" --argjson cli "$cli_pat" '.[$e]={gate:"human",approvers:[],deployCommandPatterns:(["git push * main","git push * master","git push * release/*"] + $cli + ["kubectl apply *","helm upgrade *","terraform apply *"])}' <<<"$env_json") ;;
      staging|stage|preprod) env_json=$(jq -c --arg e "$e" '.[$e]={gate:"auto"}' <<<"$env_json") ;;
      *) env_json=$(jq -c --arg e "$e" '.[$e]={gate:"none"}' <<<"$env_json") ;;
    esac
  done
  config=$(jq -cn \
    --arg pv "$SDLC_PLUGIN_VERSION" --arg platform "$platform" --argjson tier "$tier" --arg team "$team" \
    --arg owner "$owner" --arg name "$name" --arg branch "$(jq -r .defaultBranch <<<"$detected")" \
    --arg lang "$(jq -r .stack.language <<<"$detected")" --arg pm "$(jq -r .stack.packageManager <<<"$detected")" \
    --arg verify "$verify" --arg fmt "$format_cmd" --arg lint "$lint_cmd" --argjson envs "$env_json" \
    --arg ds "$deploy_staging" --arg dp "$deploy_production" \
    --arg azo "$az_org" --arg azp "$az_project" --arg azr "$az_repo" --arg reuse "$reuse" \
    --arg mt "${max_turns:-40}" --arg mb "${max_budget:-5}" --arg at "${alert:-25}" '
    { "$schema": "https://raw.githubusercontent.com/rubicarbon/ai-sdlc/main/sdlc.config.schema.json",
      version: 1, pluginVersion: $pv, platform: $platform, tier: $tier,
      repo: {owner: $owner, name: $name, defaultBranch: $branch},
      stack: ({language: $lang, packageManager: $pm} | with_entries(select(.value != ""))),
      commands: ({verify: $verify, format: $fmt, lint: $lint, deployStaging: $ds, deployProduction: $dp}
                 | with_entries(select(.value != ""))),
      environments: $envs,
      team: {mode: $team, enablePluginForTeam: ($team == "team"), codeowners: ("@" + $owner), securityOwners: ("@" + $owner)},
      review: {requiredApprovals: 1, nitCap: 5},
      cost: {maxTurns: ($mt|tonumber), maxBudgetUsd: ($mb|tonumber), alertThresholdUsd: ($at|tonumber)},
      guardrails: {requireTicket: ($tier >= 2)},
      artifacts: {dir: ".sdlc"},
      metrics: {incidentLabel: "incident", deployEnvironment: "production", maxPrs: 200},
      github: {requiredChecks: ["sdlc-pr-review"], deployWorkflow: "sdlc-deploy.yml"},
      reuse: {mattpocockSkills: $reuse} }
    | if $platform == "azure" or $platform == "both" then .azure = {organization: $azo, project: $azp, repo: $azr, workItemType: "User Story", requiredReviewers: [], pipelineName: "sdlc-pr-review", deployPipelineName: "sdlc-deploy"} else . end
    | if $platform == "none" then del(.github) else . end')
  [ -n "$mp_ver" ] && config=$(jq -c --arg v "$mp_ver" '.reuse.mattpocockSkillsVersion=$v' <<<"$config") && config=$(jq -c 'del(.reuse.mattpocockSkillsVersion)' <<<"$config")
fi
# deploy commands: the flags also apply on a re-run (they add or replace the configured ones)
if [ $mode != init ] && { [ -n "$deploy_staging" ] || [ -n "$deploy_production" ]; }; then
  config=$(jq -c --arg s "$deploy_staging" --arg p "$deploy_production" '
    if $s != "" then .commands.deployStaging = $s else . end
    | if $p != "" then .commands.deployProduction = $p else . end' <<<"$config")
fi
# the configured production command is always covered by the production gate: the exact
# string and "<command>*" join environments.prod.deployCommandPatterns (order kept, no dupes)
prod_cmd=$(jq -r '.commands.deployProduction // empty' <<<"$config")
if [ -n "$prod_cmd" ]; then
  config=$(jq -c --arg c "$prod_cmd" '
    def addu($x): if any(.[]; . == $x) then . else . + [$x] end;
    .environments.prod.gate = (.environments.prod.gate // "human")
    | .environments.prod.deployCommandPatterns =
        ((.environments.prod.deployCommandPatterns // []) | addu($c) | addu($c + "*"))' <<<"$config")
fi
tier=$(jq -r .tier <<<"$config"); platform=$(jq -r .platform <<<"$config"); team=$(jq -r '.team.mode // "solo"' <<<"$config")
art=$(jq -r '.artifacts.dir // ".sdlc"' <<<"$config")

primary="$platform"; [ "$primary" = both ] && primary=$(jq -r .platform <<<"$detected"); [ "$primary" = none ] && primary=""
[ "$platform" = both ] && [ -z "$primary" ] && primary=github

# deploy automation at tier 3: both commands, or an explicit --no-deploy; a plain re-run
# without them skips the deploy template and reports it in next_steps instead of failing
render_deploy=0; deploy_omitted=""
if [ "$tier" -ge 3 ] && [ -n "$primary" ]; then
  have_ds=$(jq -r '.commands.deployStaging // empty' <<<"$config")
  if [ $no_deploy = 1 ]; then
    deploy_omitted="--no-deploy was given"
  elif [ -n "$have_ds" ] && [ -n "$prod_cmd" ]; then
    render_deploy=1
  elif [ $mode = rerun ]; then
    deploy_omitted="commands.deployStaging / commands.deployProduction are not set in sdlc.config.json"
  else
    missing_flags=""
    [ -n "$have_ds" ] || missing_flags="--deploy-staging CMD"
    [ -n "$prod_cmd" ] || missing_flags="${missing_flags:+$missing_flags }--deploy-production CMD"
    sdlc_die 2 "run.sh: tier 3 renders the deploy workflow, which runs the commands configured in sdlc.config.json (commands.deployStaging, commands.deployProduction) with SDLC_ENVIRONMENT and SDLC_SHA exported. Pass $missing_flags (for example --deploy-production 'bash scripts/deploy.sh production \"\$SDLC_SHA\"'), or --no-deploy to set up tier 3 without deployment automation."
  fi
fi
cfg_tmp=$(sdlc_tmpfile .json); jq . <<<"$config" >"$cfg_tmp"
bash "$SDLC_PLUGIN_ROOT/scripts/config/validate.sh" "$cfg_tmp" --quiet || { rm -f "$cfg_tmp"; sdlc_die 1 "the configuration would be invalid; see errors above"; }

# ------------------------------------------------------------------ managed files
manifest="$art/managed-files.json"
[ -f "$manifest" ] && recorded=$(<"$manifest") || recorded='{}'
declare -a statuses=()
add_status() { statuses+=("$(jq -cn --arg p "$1" --arg s "$2" --arg t "${3:-}" '{path:$p,status:$s,template:$t}')"); }
writes=0

# manage <template> <dest> [extra --var args...]
# The record in managed-files.json moves to the freshly rendered hash only when that content
# now is the file (installed, upgraded, overwritten, or already equal). A template-changed or
# user-edited file keeps its previous record: otherwise the next run would compare the file
# against a hash it never had and misreport a pending template change as a user edit.
manage() {
  local tmpl="$1" dest="$2"; shift 2
  local tmp cur_hash rec_hash new_hash record=0
  tmp=$(sdlc_tmpfile)
  bash "$RENDER" "$T/$tmpl" --config "$cfg_tmp" --out "$tmp" "$@" || { rm -f "$tmp"; sdlc_die 1 "rendering $tmpl failed"; }
  new_hash=$(sdlc_sha256 "$tmp")
  rec_hash=$(jq -r --arg d "$dest" '.[$d].sha256 // empty' <<<"$recorded")
  if [ ! -f "$dest" ]; then
    if [ $check = 1 ] || ! only_allows "$dest"; then add_status "$dest" missing "$tmpl"; rm -f "$tmp"; return; fi
    place "$tmp" "$dest"; add_status "$dest" installed "$tmpl"; record=1
  else
    cur_hash=$(sdlc_sha256 "$dest")
    if [ "$cur_hash" = "$new_hash" ]; then add_status "$dest" unchanged "$tmpl"; rm -f "$tmp"; record=1
    elif [ -n "$rec_hash" ] && [ "$cur_hash" = "$rec_hash" ]; then
      # untouched by the user, but the plugin's template moved on
      if [ $check = 0 ] && { [ $upgrade = 1 ] || [ $force = 1 ]; } && only_allows "$dest"; then
        place "$tmp" "$dest"; add_status "$dest" upgraded "$tmpl"; record=1
      else add_status "$dest" template-changed "$tmpl"; rm -f "$tmp"; fi
    else
      if [ $check = 0 ] && [ $force = 1 ] && only_allows "$dest"; then
        place "$tmp" "$dest"; add_status "$dest" overwritten "$tmpl"; record=1
      else add_status "$dest" user-edited "$tmpl"; rm -f "$tmp"; fi
    fi
  fi
  [ $record = 1 ] || return 0
  recorded=$(jq -c --arg d "$dest" --arg h "$new_hash" --arg t "$tmpl" '.[$d]={template:$t,sha256:$h}' <<<"$recorded")
}
place() { if [ $dry = 1 ]; then rm -f "$1"; return; fi; mkdir -p "$(dirname "$2")"; mv "$1" "$2"; writes=$((writes+1)); }
# --only <path> (repeatable) limits --upgrade / --force and the creation of missing files
only_allows() { [ ${#only[@]} -eq 0 ] && return 0; local o; for o in "${only[@]}"; do [ "$o" = "$1" ] && return 0; done; return 1; }

# artifact_dir <dir>: one status per artifact directory. .gitkeep is only a placeholder so the
# directory survives in git; a directory that exists without it is "unchanged".
artifact_dir() {
  local d="$1"
  if [ -d "$d" ]; then add_status "$d/" unchanged ""; return; fi
  if [ $check = 1 ] || [ $dry = 1 ]; then add_status "$d/" missing ""; return; fi
  mkdir -p "$d" && : >"$d/.gitkeep" || sdlc_die 1 "cannot create $d"
  writes=$((writes+1)); add_status "$d/" installed ""
}

# create_once <template> <dest>: rendered on first run, then owned by the user (never compared)
create_once() {
  if [ -f "$2" ]; then add_status "$2" kept "$1"; return; fi
  if [ $check = 1 ]; then add_status "$2" missing "$1"; return; fi
  local tmp; tmp=$(sdlc_tmpfile); bash "$RENDER" "$T/$1" --config "$cfg_tmp" --out "$tmp" || { rm -f "$tmp"; sdlc_die 1 "rendering $1 failed"; }
  place "$tmp" "$2"; add_status "$2" installed "$1"
}

# claude_md: create from template, or maintain our block inside an existing CLAUDE.md / AGENTS.md
claude_md() {
  local target=CLAUDE.md; [ ! -f CLAUDE.md ] && [ -f AGENTS.md ] && target=AGENTS.md
  local tmp; tmp=$(sdlc_tmpfile); bash "$RENDER" "$T/CLAUDE.md.tmpl" --config "$cfg_tmp" --out "$tmp" || { rm -f "$tmp"; sdlc_die 1 "rendering CLAUDE.md failed"; }
  local title; title=$(head -n1 "$tmp")
  local block; block=$(printf '<!-- ai-sdlc:begin (managed by /ai-sdlc:sdlc-init; edit outside this block) -->\n%s\n<!-- ai-sdlc:end -->' "$(sed '1d' "$tmp")")
  rm -f "$tmp"
  if [ ! -f "$target" ]; then
    if [ $check = 1 ]; then add_status "$target" missing CLAUDE.md.tmpl; return; fi
    # created in block form so later runs recognise and replace only the managed part
    [ $dry = 1 ] || { printf '%s\n\n%s\n' "$title" "$block" >"$target"; writes=$((writes+1)); }
    add_status "$target" installed CLAUDE.md.tmpl; return
  fi
  local current; current=$(<"$target")
  local new
  if [[ "$current" == *"<!-- ai-sdlc:begin"* ]]; then
    new=$(awk -v blk="$block" 'BEGIN{skip=0} /<!-- ai-sdlc:begin/{print blk; skip=1; next} /<!-- ai-sdlc:end -->/{skip=0; next} !skip{print}' "$target")
  else
    new=$(printf '%s\n\n%s\n' "$current" "$block")
  fi
  if [ "$new" = "$current" ]; then add_status "$target" unchanged CLAUDE.md.tmpl
  elif [ $check = 1 ]; then add_status "$target" template-changed CLAUDE.md.tmpl
  elif [[ "$current" == *"<!-- ai-sdlc:begin"* ]] && [ $upgrade = 0 ] && [ $force = 0 ] && [ $mode = rerun ]; then add_status "$target" template-changed CLAUDE.md.tmpl
  else [ $dry = 1 ] || { printf '%s\n' "$new" >"$target"; writes=$((writes+1)); }; add_status "$target" "$( [[ "$current" == *"<!-- ai-sdlc:begin"* ]] && echo upgraded || echo block-appended )" CLAUDE.md.tmpl
  fi
}

# settings: merge fragments, never clobber
settings_merge() {
  local frags=() f tmp
  for f in settings.json.tmpl "settings.$primary.json.tmpl"; do
    [ -f "$T/$f" ] || continue
    tmp=$(sdlc_tmpfile .json); bash "$RENDER" "$T/$f" --config "$cfg_tmp" --out "$tmp" || sdlc_die 1 "rendering $f failed"; frags+=("$tmp")
  done
  if [ "$team" = team ] && [ "$(jq -r '.team.enablePluginForTeam // false' <<<"$config")" = true ]; then
    tmp=$(sdlc_tmpfile .json); bash "$RENDER" "$T/settings.team.json.tmpl" --config "$cfg_tmp" --out "$tmp" || sdlc_die 1 "rendering settings.team.json.tmpl failed"; frags+=("$tmp")
  fi
  local before after
  before=$( [ -f .claude/settings.json ] && jq -c . .claude/settings.json || echo '{}')
  after=$(bash "$SDLC_PLUGIN_ROOT/scripts/init/merge-settings.sh" .claude/settings.json "${frags[@]}" --dry-run | jq -c .)
  rm -f "${frags[@]}"
  if [ "$before" = "$after" ]; then add_status .claude/settings.json unchanged settings.json.tmpl
  elif [ $check = 1 ]; then add_status .claude/settings.json template-changed settings.json.tmpl
  else [ $dry = 1 ] || { mkdir -p .claude; jq . <<<"$after" >.claude/settings.json; writes=$((writes+1)); }; add_status .claude/settings.json "$( [ -f .claude/settings.json ] && echo merged || echo installed )" settings.json.tmpl
  fi
}

gitignore_lines() {
  local want=("$art/ACTIVE_TICKET" "$art/FIX_MODE" "$art/UNLOCK_PROTECTED" "$art/release/" "$art/tmp/") l changed=0
  for l in "${want[@]}"; do
    grep -qxF "$l" .gitignore 2>/dev/null && continue
    changed=1; [ $check = 1 ] || [ $dry = 1 ] || { [ -s .gitignore ] && [ "$(tail -c1 .gitignore | od -An -c | tr -d ' ')" != '\n' ] && echo >>.gitignore; echo "$l" >>.gitignore; }
  done
  [ $changed = 1 ] && [ $check = 0 ] && [ $dry = 0 ] && writes=$((writes+1))
  add_status .gitignore "$( [ $changed = 1 ] && { [ $check = 1 ] && echo missing || echo appended; } || echo unchanged )" ""
}

# ------------------------------------------------------------------ render plan by tier
claude_md
create_once CONTEXT.md.tmpl CONTEXT.md
manage agents/domain.md.tmpl docs/agents/domain.md
settings_merge
gitignore_lines
if [ "$tier" -ge 1 ]; then
  manage REVIEW.md.tmpl REVIEW.md --var "REVIEW_NIT_CAP=$(jq -r '.review.nitCap // 5' <<<"$config")"
  if [ -n "$primary" ]; then manage "agents/issue-tracker-$primary.md.tmpl" docs/agents/issue-tracker.md; fi
  for d in features verify releases postmortems metrics/cost; do artifact_dir "$art/$d"; done
  artifact_dir docs/adr
fi
if [ "$tier" -ge 3 ] && [ -n "$primary" ]; then
  for p in $( [ "$platform" = both ] && echo "github azure" || echo "$primary" ); do
    case "$p" in
      github)
        for w in "$T"/github/workflows/*.yml; do
          [ "${w##*/}" = sdlc-deploy.yml ] && [ $render_deploy = 0 ] && continue
          manage "github/workflows/${w##*/}" ".github/workflows/${w##*/}"
        done
        manage github/PULL_REQUEST_TEMPLATE.md .github/PULL_REQUEST_TEMPLATE.md
        manage github/CODEOWNERS.tmpl .github/CODEOWNERS ;;
      azure)
        for w in "$T"/azure/pipelines/*.yml; do
          [ "${w##*/}" = sdlc-deploy.yml ] && [ $render_deploy = 0 ] && continue
          manage "azure/pipelines/${w##*/}" ".azuredevops/pipelines/${w##*/}"
        done
        manage azure/pull_request_template.md .azuredevops/pull_request_template.md
        manage azure/branch-policies.json .azuredevops/branch-policies.json --var "REVIEW_REQUIRED_APPROVALS=$(jq -r '.review.requiredApprovals // 1' <<<"$config")" --var "AZURE_PIPELINE_NAME=$(jq -r '.azure.pipelineName // "sdlc-pr-review"' <<<"$config")" ;;
    esac
  done
fi

# ------------------------------------------------------------------ write config + manifest
if [ $check = 0 ] && [ $dry = 0 ]; then
  if [ ! -f sdlc.config.json ] || [ "$(jq -c . sdlc.config.json)" != "$(jq -c . "$cfg_tmp")" ]; then cp "$cfg_tmp" sdlc.config.json; writes=$((writes+1)); add_status sdlc.config.json "$( [ $mode = init ] && echo installed || echo updated )" ""; else add_status sdlc.config.json unchanged ""; fi
  mkdir -p "$art"; jq . <<<"$recorded" >"$manifest"
else
  add_status sdlc.config.json "$( [ -f sdlc.config.json ] && echo unchanged || echo missing )" ""
fi
rm -f "$cfg_tmp"

statuses_json=$(printf '%s\n' "${statuses[@]}" | jq -cs .)
# drift = the plugin moved or a file is missing; a user-edited file is the user's business (reported, not drift)
pending=$(jq -c '[.[] | select(.status | IN("template-changed","missing"))]' <<<"$statuses_json")
n_pending=$(jq 'length' <<<"$pending")
user_edited=$(jq -c '[.[] | select(.status == "user-edited")]' <<<"$statuses_json")

# ------------------------------------------------------------------ next steps
steps=()
mp_installed=$(jq -r '.mattpocock.installed' <<<"$detected")
if [ "$mp_installed" != true ]; then steps+=("Install the inner loop: /plugin install mattpocock-skills (official marketplace), then restart Claude Code."); fi
if [ "$(jq -r '.mattpocock.editable_copies | length' <<<"$detected")" -gt 0 ]; then steps+=("WARNING: an editable copy of mattpocock skills exists in this repo ($(jq -r '.mattpocock.editable_copies | join(", ")' <<<"$detected")). Running both the plugin and the copy loads every skill twice; remove one."); fi
if [ "$primary" = azure ]; then steps+=("docs/agents/issue-tracker.md is written for Azure DevOps. If you run /mattpocock-skills:setup-matt-pocock-skills, answer 'Other' for the tracker and keep that file, or skip the tracker section."); fi
if [ "$platform" = none ]; then steps+=("Platform 'none': run /mattpocock-skills:setup-matt-pocock-skills and choose 'Local markdown' as the tracker."); fi
case "$primary" in
  github) [ "$(jq -r .cli.gh.authenticated <<<"$detected")" = true ] || steps+=("Authenticate the GitHub CLI: gh auth login") ;;
  azure)  [ "$(jq -r .cli.az.devopsExtension <<<"$detected")" = true ] || steps+=("Install the Azure DevOps CLI extension: az extension add --name azure-devops"); [ "$(jq -r .cli.az.authenticated <<<"$detected")" = true ] || steps+=("Authenticate the Azure CLI: az login (or export AZURE_DEVOPS_EXT_PAT)") ;;
esac
[ "$tier" -ge 2 ] && [ -n "$primary" ] && steps+=("Protect the default branch (human approval required to merge): sdlc-platform branch_protect_apply $(jq -r '.repo.defaultBranch // "main"' <<<"$config")")
if [ "$tier" -ge 3 ] && [ -n "$primary" ]; then
  steps+=("Commit the CI files, then register them: sdlc-platform ci_workflow_install")
  steps+=("Create the CI secret ANTHROPIC_API_KEY and the production approval rule (GitHub environment 'production' with required reviewers, or the Azure environment's Approvals check): see docs/PLATFORM-SETUP.md.")
  if [ $render_deploy = 1 ]; then
    steps+=("The deploy workflow runs commands.deployStaging and commands.deployProduction from sdlc.config.json with SDLC_ENVIRONMENT and SDLC_SHA exported; the production command is covered by the gate-production hook (environments.prod.deployCommandPatterns).")
  else
    steps+=("Deployment automation was omitted ($deploy_omitted): no deploy workflow was rendered. To add it, re-run with --deploy-staging CMD --deploy-production CMD (SDLC_ENVIRONMENT and SDLC_SHA are exported to the commands).")
  fi
fi
[ "$team" = team ] && steps+=("Commit .claude/settings.json: teammates get ai-sdlc and mattpocock-skills enabled automatically.")
steps+=("Commit the rendered files.")
if [ "$tier" -eq 0 ]; then steps+=("Capture the metrics baseline NOW, before Tier 1 changes how work flows: /ai-sdlc:sdlc-metrics-baseline"); else steps+=("Metrics baseline: it must be taken before Tier 1. You started at tier $tier, so run /ai-sdlc:sdlc-metrics-baseline --force once to record a late baseline (it is labelled as such)."); fi

if [ $mode = rerun ] && [ $check = 0 ] && [ $upgrade = 0 ] && [ $force = 0 ] && [ "$writes" -eq 0 ] && [ "$n_pending" -eq 0 ]; then
  note "already initialised: sdlc.config.json and every managed file are up to date (nothing written)"
  result=already-initialised
elif [ $check = 1 ]; then
  result=$( [ "$n_pending" -eq 0 ] && echo clean || echo drift )
else
  result=$mode
fi
jq -cn --arg r "$result" --arg p "$platform" --argjson t "$tier" --arg team "$team" --argjson w "$writes" --argjson files "$statuses_json" --argjson pending "$pending" --argjson ue "$user_edited" \
  --argjson steps "$(printf '%s\n' "${steps[@]}" | jq -R . | jq -cs 'map(select(length>0))')" \
  '{result:$r, platform:$p, tier:$t, team:$team, writes:$w, files:$files, pending:$pending, user_edited:$ue, next_steps:$steps}'
if [ $check = 1 ]; then
  [ "$n_pending" -eq 0 ] && exit 0
  jq -r '.[] | "ai-sdlc: \(.status): \(.path)"' <<<"$pending" >&2; exit 1
fi
[ "$n_pending" -gt 0 ] && jq -r '.[] | "ai-sdlc: \(.status): \(.path) " + (if .status == "template-changed" then "(re-run with --upgrade to apply the template change)" else "(created by a run without --check / --dry-run" + (if .template != "" then ", subject to --only" else "" end) + ")" end)' <<<"$pending" >&2
[ "$(jq length <<<"$user_edited")" -gt 0 ] && jq -r '.[] | "ai-sdlc: user-edited: \(.path) (kept; --force overwrites)"' <<<"$user_edited" >&2
exit 0
