#!/usr/bin/env bash
# _project.sh: silent exit 0 outside an sdlc project; config found from a subdirectory; optional mode.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"

plain="$EVAL_TMP/plain"; mkdir -p "$plain/src/deep"; git -C "$plain" init -q
proj="$EVAL_TMP/proj";   mkdir -p "$proj/src/deep"; git -C "$proj" init -q
printf '{"version":1,"platform":"github","tier":1,"artifacts":{"dir":".sdlc"}}' > "$proj/sdlc.config.json"

# Outside an sdlc project the sourcing script exits 0 before doing anything else.
out=$(cd "$plain/src/deep" && bash -c '. "$1/scripts/_root.sh" || exit 2; . "$SDLC_PLUGIN_ROOT/scripts/_project.sh"; echo REACHED' _ "$P"); rc=$?
assert_eq "0" "$rc" "plain repo: exit 0"
assert_eq "" "$out" "plain repo: nothing printed, script body never reached"

# Inside, from a nested directory, the project dir is the config's directory.
out=$(cd "$proj/src/deep" && bash -c '. "$1/scripts/_root.sh" || exit 2; . "$SDLC_PLUGIN_ROOT/scripts/_project.sh"; printf "%s|%s" "$SDLC_PROJECT_DIR" "$(sdlc_config .platform)"' _ "$P")
pn=$(cd "$proj" && pwd -P)
assert_eq "$pn|github" "$out" "sdlc project found from nested cwd; sdlc_config reads a value"
out=$(cd "$proj" && bash -c '. "$1/scripts/_root.sh" || exit 2; . "$SDLC_PLUGIN_ROOT/scripts/_project.sh"; sdlc_artifacts_dir' _ "$P")
assert_eq "$pn/.sdlc" "$out" "artifacts dir resolves against the project"

# Optional mode continues with an empty project dir.
out=$(cd "$plain" && SDLC_PROJECT_OPTIONAL=1 bash -c '. "$1/scripts/_root.sh" || exit 2; . "$SDLC_PLUGIN_ROOT/scripts/_project.sh"; echo "dir=[$SDLC_PROJECT_DIR]"' _ "$P")
assert_eq "dir=[]" "$out" "optional mode: continues with empty SDLC_PROJECT_DIR"

# Speed: the silent path spawns nothing beyond bash itself.
cd "$plain" || exit 1
min_ms() { local best=999999 s e d; for _ in 1 2 3 4 5; do s=$(date +%s%N); "$@" >/dev/null 2>&1; e=$(date +%s%N); d=$(( (e - s) / 1000000 )); [ "$d" -lt "$best" ] && best=$d; done; echo "$best"; }
silent_run() { bash -c '. "$1/scripts/_root.sh" || exit 2; . "$SDLC_PLUGIN_ROOT/scripts/_project.sh"' _ "$P"; }
base_run() { bash -c 'true'; }
per=$(min_ms silent_run); base=$(min_ms base_run)
echo "  info  silent path (min of 5): ${per} ms per run; bare bash startup on this machine: ${base} ms"
if [ $(( per - base )) -le 60 ]; then _ok "silent path adds at most 60 ms over bash startup"; else _fail "silent path too slow" "$(( per - base )) ms over baseline"; fi

eval_done
