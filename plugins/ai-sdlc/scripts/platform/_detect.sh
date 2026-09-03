#!/usr/bin/env bash
# platform_detect — print "github" or "azure" from the git remote, exit 3 when unknown.
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"

remote=$(git remote get-url "${SDLC_GIT_REMOTE:-origin}" 2>/dev/null || true)
case "$remote" in
  *github.com[:/]*) echo github; exit 0 ;;
  *dev.azure.com/*|*visualstudio.com/*|*ssh.dev.azure.com*|*vs-ssh.visualstudio.com*) echo azure; exit 0 ;;
esac
if [ -z "$remote" ]; then
  sdlc_die 3 "not supported on this platform: no git remote '${SDLC_GIT_REMOTE:-origin}' to detect from"
fi
sdlc_die 3 "not supported on this platform: remote '$remote' is neither GitHub nor Azure DevOps (set \"platform\" in sdlc.config.json or pass --platform)"
