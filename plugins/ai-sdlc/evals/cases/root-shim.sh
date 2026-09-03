#!/usr/bin/env bash
# The CLAUDE_PLUGIN_ROOT resolver shim: variable set, unset, empty, wrong, and cache fallback.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
probe() {  # probe [env...] -> prints "<root>|<source>|<version>" via a child bash that sources the shim
  env "$@" bash -c '. "$1/scripts/_root.sh" && printf "%s|%s|%s" "$SDLC_PLUGIN_ROOT" "$SDLC_ROOT_SOURCE" "$SDLC_PLUGIN_VERSION"' _ "$P"
}
pn=$(cd "$P" && pwd -P)

out=$(probe CLAUDE_PLUGIN_ROOT="$pn");           assert_eq "$pn|CLAUDE_PLUGIN_ROOT|0.1.0" "$out" "variable set to the real root is used"
out=$(probe -u CLAUDE_PLUGIN_ROOT);              assert_eq "$pn|script-path|0.1.0" "$out" "variable unset falls back to the script path"
out=$(probe CLAUDE_PLUGIN_ROOT=);                assert_eq "$pn|script-path|0.1.0" "$out" "variable empty falls back to the script path"
out=$(probe CLAUDE_PLUGIN_ROOT='${CLAUDE_PLUGIN_ROOT}'); assert_eq "$pn|script-path|0.1.0" "$out" "literal unexpanded placeholder falls back to the script path"
out=$(probe CLAUDE_PLUGIN_ROOT=/);               assert_eq "$pn|script-path|0.1.0" "$out" "variable '/' is rejected, never used"
out=$(probe CLAUDE_PLUGIN_ROOT="$EVAL_TMP");     assert_eq "$pn|script-path|0.1.0" "$out" "variable pointing at a non-plugin dir is rejected"

# Sourced through a relative path with `..` (how hooks and adapter scripts reach it).
out=$(cd "$P/hooks" && env -u CLAUDE_PLUGIN_ROOT bash -c '. "../scripts/_root.sh"; printf "%s|%s" "$SDLC_PLUGIN_ROOT" "$SDLC_ROOT_SOURCE"')
assert_eq "$pn|script-path" "$out" "relative source path from hooks/ resolves to the real root"
out=$(cd "$P/scripts/platform/github" && env -u CLAUDE_PLUGIN_ROOT bash -c '. "../../_root.sh"; printf "%s|%s" "$SDLC_PLUGIN_ROOT" "$SDLC_ROOT_SOURCE"')
assert_eq "$pn|script-path" "$out" "relative source path from an adapter dir resolves to the real root"
out=$(env -u CLAUDE_PLUGIN_ROOT bash -c '. "$1/scripts/platform/../_root.sh"; printf "%s" "$SDLC_PLUGIN_ROOT"' _ "$P")
assert_eq "$pn" "$out" "absolute source path containing .. resolves to the real root"

# Windows spelling of the same root must normalise to the same value.
win=$(cd "$P" && pwd -W 2>/dev/null || true)
if [ -n "$win" ]; then
  out=$(probe CLAUDE_PLUGIN_ROOT="$win");        assert_eq "$pn|CLAUDE_PLUGIN_ROOT|0.1.0" "$out" "Windows path spelling normalises"
fi

# Cache fallback: copy the shim somewhere that is not a plugin root, point HOME at a fake cache.
fake="$EVAL_TMP/fakehome"
mkdir -p "$fake/.claude/plugins/cache/ai-sdlc-kit/ai-sdlc/0.9.9/.claude-plugin" "$fake/.claude/plugins/cache/ai-sdlc-kit/ai-sdlc/0.9.9/scripts" "$EVAL_TMP/orphan/scripts"
printf '{"name":"ai-sdlc","version":"0.9.9"}' > "$fake/.claude/plugins/cache/ai-sdlc-kit/ai-sdlc/0.9.9/.claude-plugin/plugin.json"
cp "$P/scripts/_root.sh" "$EVAL_TMP/orphan/scripts/_root.sh"
out=$(env -u CLAUDE_PLUGIN_ROOT HOME="$fake" bash -c '. "$1/scripts/_root.sh" && printf "%s|%s|%s" "$SDLC_PLUGIN_ROOT" "$SDLC_ROOT_SOURCE" "$SDLC_PLUGIN_VERSION"' _ "$EVAL_TMP/orphan")
assert_match "/fakehome/.claude/plugins/cache/ai-sdlc-kit/ai-sdlc/0.9.9\|plugin-cache\|0.9.9$" "$out" "orphaned script finds the plugin in the cache"

# Nothing anywhere: must fail loudly, never yield "/" or empty.
out=$(env -u CLAUDE_PLUGIN_ROOT HOME="$EVAL_TMP/nohome" bash -c '. "$1/scripts/_root.sh"; echo "root=[${SDLC_PLUGIN_ROOT:-}] rc=$?"' _ "$EVAL_TMP/orphan" 2>&1)
assert_match "cannot locate the plugin root" "$out" "missing root fails with a clear message"
assert_not_match 'root=\[/\]' "$out" "missing root never resolves to /"
rc=$(env -u CLAUDE_PLUGIN_ROOT HOME="$EVAL_TMP/nohome" bash -c '. "$1/scripts/_root.sh" || exit 2; exit 0' _ "$EVAL_TMP/orphan" 2>/dev/null; echo $?)
assert_eq "2" "$rc" "caller can turn the failure into exit 2"

eval_done
