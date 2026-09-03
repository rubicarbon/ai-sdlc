#!/usr/bin/env bash
# run.sh — regression-test the plugin's own configuration.
#
#   bash plugins/ai-sdlc/evals/run.sh            run every case
#   bash plugins/ai-sdlc/evals/run.sh root glob  run cases whose file name contains a word
#
# Each case is a bash script under evals/cases/ that sources evals/_assert.sh
# and ends with eval_done. Cases get a fresh scratch directory in $EVAL_TMP.
# No LLM is involved: hooks are fed fixture stdin, adapters run against the
# bundled CLI mocks, and init runs non-interactively into scratch repos.
set -u
here=$(CDPATH= cd -- "${0%/*}" && pwd -P)
export EVAL_ROOT="$here"
export SDLC_PLUGIN_ROOT_FOR_EVALS="${here%/evals}"
scratch_base="${EVAL_SCRATCH:-$here/../../../.dev/scratch/evals}"
mkdir -p "$scratch_base"
scratch_base=$(CDPATH= cd -- "$scratch_base" && pwd -P)

filters=("$@")
total=0; failed=0; failed_names=()
for case_file in "$here"/cases/*.sh; do
  name="${case_file##*/}"; name="${name%.sh}"
  if [ ${#filters[@]} -gt 0 ]; then
    keep=0; for f in "${filters[@]}"; do [[ "$name" == *"$f"* ]] && keep=1; done
    [ $keep = 1 ] || continue
  fi
  total=$((total+1))
  EVAL_TMP="$scratch_base/$name"
  rm -rf "$EVAL_TMP"; mkdir -p "$EVAL_TMP"
  echo "== $name"
  if ! EVAL_NAME="$name" EVAL_TMP="$EVAL_TMP" bash "$case_file"; then
    failed=$((failed+1)); failed_names+=("$name")
  fi
done
echo
echo "evals: $total case(s), $failed failed"
if [ "$failed" -gt 0 ]; then printf '  - %s\n' "${failed_names[@]}"; exit 1; fi
exit 0
