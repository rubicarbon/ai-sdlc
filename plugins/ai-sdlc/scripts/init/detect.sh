#!/usr/bin/env bash
# detect.sh — inspect a repository before /sdlc-init asks its questions. Prints one JSON object:
# platform and remote, CLI presence and authentication, stack and verify-command candidates,
# mattpocock-skills installation (plugin vs editable copies), existing rendered files.
#
#   detect.sh [--repo-dir DIR]
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
dir="$PWD"
while [ $# -gt 0 ]; do case "$1" in --repo-dir) dir="$2"; shift 2 ;; *) sdlc_die 2 "detect.sh [--repo-dir DIR]" ;; esac; done
cd "$dir" || sdlc_die 2 "detect.sh: cannot cd to $dir"
if [ "${SDLC_PLATFORM_MOCK:-0}" = "1" ]; then export PATH="$SDLC_PLUGIN_ROOT/scripts/platform/_mocks/bin:$PATH"; fi
t() { if sdlc_has timeout; then timeout 20 "$@"; else "$@"; fi; }

remote=$(git remote get-url origin 2>/dev/null || true)
platform=$(SDLC_GIT_REMOTE=origin bash "$SDLC_PLUGIN_ROOT/scripts/platform/_detect.sh" 2>/dev/null || echo none)
default_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||'); [ -n "$default_branch" ] || default_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
[ "$default_branch" = HEAD ] && default_branch=main

owner=""; name=""; az_org=""; az_project=""; az_repo=""
case "$remote" in
  *github.com[:/]*) r="${remote%.git}"; r="${r#*github.com[:/]}"; r="${r#*github.com/}"; owner="${r%%/*}"; name="${r#*/}" ;;
  https://*dev.azure.com/*/*/_git/*) r="${remote#https://}"; r="${r#*@}"; r="${r#dev.azure.com/}"; az_org="https://dev.azure.com/${r%%/*}"; r="${r#*/}"; az_project="${r%%/_git/*}"; az_repo="${r##*/_git/}"; name="$az_repo"; owner="${az_org##*/}" ;;
  *ssh.dev.azure.com:v3/*) r="${remote#*ssh.dev.azure.com:v3/}"; az_org="https://dev.azure.com/${r%%/*}"; r="${r#*/}"; az_project="${r%%/*}"; az_repo="${r##*/}"; name="$az_repo"; owner="${az_org##*/}" ;;
esac

gh_present=false; gh_auth=false; az_present=false; az_auth=false; az_ext=false
if sdlc_has gh; then gh_present=true; t gh auth status >/dev/null 2>&1 && gh_auth=true; fi
if sdlc_has az; then az_present=true; t az extension show --name azure-devops >/dev/null 2>&1 && az_ext=true; { [ -n "${AZURE_DEVOPS_EXT_PAT:-}" ] || t az account show >/dev/null 2>&1; } && az_auth=true; fi

language=""; pm=""; candidates=()
if [ -f package.json ]; then
  language=javascript; [ -f tsconfig.json ] && language=typescript
  pm=npm; [ -f pnpm-lock.yaml ] && pm=pnpm; [ -f yarn.lock ] && pm=yarn; [ -f bun.lockb ] || [ -f bun.lock ] && pm=bun
  for s in verify check ci test; do
    if jq -e --arg s "$s" '.scripts[$s] != null' package.json >/dev/null 2>&1; then
      if [ "$s" = test ]; then candidates+=("$pm test"); else candidates+=("$pm run $s"); fi
    fi
  done
fi
if [ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f setup.py ]; then
  language="${language:-python}"; [ -f poetry.lock ] && pm="${pm:-poetry}"; [ -f uv.lock ] && pm="${pm:-uv}"
  if [ "${pm:-}" = poetry ]; then candidates+=("poetry run pytest"); elif [ "${pm:-}" = uv ]; then candidates+=("uv run pytest"); else candidates+=("pytest"); fi
fi
[ -f go.mod ] && { language="${language:-go}"; candidates+=("go test ./..."); }
[ -f Cargo.toml ] && { language="${language:-rust}"; pm="${pm:-cargo}"; candidates+=("cargo test"); }
if ls ./*.csproj ./*.sln >/dev/null 2>&1 || ls ./*/*.csproj >/dev/null 2>&1; then language="${language:-csharp}"; pm="${pm:-dotnet}"; candidates+=("dotnet test"); fi
[ -f pom.xml ] && { language="${language:-java}"; pm="${pm:-maven}"; candidates+=("mvn -q test"); }
{ [ -f build.gradle ] || [ -f build.gradle.kts ]; } && { language="${language:-java}"; pm="${pm:-gradle}"; candidates+=("./gradlew test"); }
[ -f Gemfile ] && { language="${language:-ruby}"; pm="${pm:-bundler}"; candidates+=("bundle exec rspec"); }
if [ -f Makefile ]; then for tgt in verify check test; do grep -qE "^$tgt:" Makefile && candidates+=("make $tgt"); done; fi
[ ${#candidates[@]} -gt 0 ] || candidates+=("echo 'set commands.verify in sdlc.config.json'")

# Deploy command proposals for the tier 3 interview: only when the repository already has the
# conventional script. run.sh never adopts them on its own; the flags stay explicit.
deploy_staging=""; deploy_production=""
if [ -f scripts/deploy.sh ]; then
  deploy_staging='bash scripts/deploy.sh staging "$SDLC_SHA"'
  deploy_production='bash scripts/deploy.sh production "$SDLC_SHA"'
fi

mp=$(bash "$SDLC_PLUGIN_ROOT/scripts/reuse/check-mattpocock.sh" --project "$dir" --json 2>/dev/null || true)
[ -n "$mp" ] || mp='{"installed":false,"editable_copies":[]}'

exists() { if [ -e "$1" ]; then echo true; else echo false; fi; }
j() { printf '%s\n' "$@" | jq -R . | jq -cs 'map(select(length>0))'; }
jq -cn \
  --arg platform "$platform" --arg remote "$remote" --arg branch "$default_branch" --arg owner "$owner" --arg name "$name" \
  --arg azo "$az_org" --arg azp "$az_project" --arg azr "$az_repo" \
  --argjson ghp "$gh_present" --argjson gha "$gh_auth" --argjson azp_ "$az_present" --argjson aza "$az_auth" --argjson aze "$az_ext" \
  --arg lang "$language" --arg pm "$pm" --argjson cands "$(j "${candidates[@]}")" --argjson mp "$mp" \
  --arg ds "$deploy_staging" --arg dp "$deploy_production" \
  --argjson cfg "$(exists sdlc.config.json)" --argjson claude "$(exists CLAUDE.md)" --argjson agents "$(exists AGENTS.md)" --argjson ctx "$(exists CONTEXT.md)" --argjson review "$(exists REVIEW.md)" --argjson settings "$(exists .claude/settings.json)" --argjson tracker "$(exists docs/agents/issue-tracker.md)" --argjson scratch "$(exists .scratch)" \
  '{platform:$platform, remote:$remote, defaultBranch:$branch, repo:{owner:$owner,name:$name},
    azure:{organization:$azo,project:$azp,repo:$azr},
    cli:{gh:{present:$ghp,authenticated:$gha}, az:{present:$azp_,authenticated:$aza,devopsExtension:$aze}},
    stack:{language:$lang,packageManager:$pm}, verifyCandidates:$cands,
    deployCandidates:{staging:$ds,production:$dp}, mattpocock:$mp,
    existing:{config:$cfg,claudeMd:$claude,agentsMd:$agents,contextMd:$ctx,reviewMd:$review,settings:$settings,issueTracker:$tracker,scratch:$scratch}}'
