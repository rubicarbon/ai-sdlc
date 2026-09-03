#!/usr/bin/env bash
# gitignore-style matcher used by every hook that reads glob lists from config.
. "${EVAL_ROOT}/_assert.sh"
. "$SDLC_PLUGIN_ROOT_FOR_EVALS/scripts/_glob.sh"

m() { if sdlc_glob_match "$1" "$2"; then echo yes; else echo no; fi; }

assert_eq yes "$(m '*.test.ts' 'src/a/b.test.ts')"            'basename pattern matches at depth'
assert_eq no  "$(m '*.test.ts' 'src/a/b.ts')"                 'basename pattern rejects other files'
assert_eq yes "$(m '**/__tests__/**' 'pkg/__tests__/x.js')"   '**/dir/** matches nested'
assert_eq yes "$(m 'secrets/**' 'secrets/k.pem')"             'dir/** at root'
assert_eq yes "$(m 'secrets/**' 'ops/secrets/k.pem')"         'dir/** at depth (deny-style)'
assert_eq no  "$(m '/secrets/**' 'ops/secrets/k.pem')"        'anchored /dir/** rejects nested copy'
assert_eq yes "$(m '/secrets/**' 'secrets/k.pem')"            'anchored /dir/** matches at root'
assert_eq yes "$(m '.env*' '.env.local')"                     '.env* matches .env.local'
assert_eq yes "$(m '.env*' 'app/.env')"                       '.env* matches nested .env'
assert_eq no  "$(m '.env*' 'environment.ts')"                 '.env* rejects environment.ts'
assert_eq yes "$(m '.github/workflows/**' '.github/workflows/ci.yml')" 'workflow glob'
assert_eq yes "$(m 'CODEOWNERS' '.github/CODEOWNERS')"        'bare filename at depth'
assert_eq yes "$(m 'build/' 'build/out/x.o')"                 'trailing slash means directory'
assert_eq yes "$(m 'tests/**/*.py' 'tests/unit/deep/t.py')"   '** in the middle'
assert_eq no  "$(m 'tests/**/*.py' 'tests/unit/deep/t.txt')"  '** in the middle, wrong extension'
assert_eq yes "$(m 'src/?.js' 'src/a.js')"                    '? matches one char'
assert_eq no  "$(m 'src/?.js' 'src/ab.js')"                   '? rejects two chars'
assert_eq yes "$(m '*.lock' 'C:\\repo\\pnpm.lock')"           'backslash path normalised'
SDLC_PROJECT_DIR=/c/repo
assert_eq yes "$(m '/sdlc.config.json' '/c/repo/sdlc.config.json')" 'absolute path stripped of project prefix'
assert_eq no  "$(m '/sdlc.config.json' '/c/repo/sub/sdlc.config.json')" 'anchored file rejects nested'
if sdlc_glob_any 'src/x.spec.ts' '*.test.ts' '*.spec.ts'; then r=yes; else r=no; fi
assert_eq yes "$r" 'glob_any with several patterns'

eval_done
