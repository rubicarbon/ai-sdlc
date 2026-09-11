#!/usr/bin/env bash
# init on a repository with no commits: the default branch is the real branch name, never the
# two-line "HEAD\nmain" that `git rev-parse --abbrev-ref HEAD` produces on an unborn repository
# (it prints HEAD *and* exits 128, so a `|| echo main` fallback appends a second line). A branch
# name with a newline in it silently disables the production gate, because the gate compiles the
# pattern to an anchored ERE. detect.sh also reports whether the directory is a repository at all,
# and tier 3 refuses the placeholder verify command instead of rendering a check that verifies
# nothing.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
RUN="$P/scripts/init/run.sh"
DETECT="$P/scripts/init/detect.sh"
export SDLC_PLATFORM_MOCK=1 HOME="$EVAL_TMP/home"; mkdir -p "$HOME"

# unborn_repo <dir> <branch> [remote] : git init only, no commit, so HEAD points at an unborn ref
unborn_repo() {
  rm -rf "$1"; mkdir -p "$1"; git -C "$1" init -q -b "$2"
  git -C "$1" config user.email e@x; git -C "$1" config user.name e; git -C "$1" config core.autocrlf false
  [ -n "${3:-}" ] && git -C "$1" remote add origin "$3"
  printf '{"name":"x","scripts":{"verify":"npm run lint && vitest run"}}\n' >"$1/package.json"
}

echo "-- detect.sh on an unborn repository"
u="$EVAL_TMP/unborn"; unborn_repo "$u" main https://github.com/mock-org/mock-repo.git
det=$(bash "$DETECT" --repo-dir "$u"); rc=$?
assert_eq "0" "$rc" "detect.sh exits 0 on a repository with no commits"
assert_eq "main" "$(jq -r .defaultBranch <<<"$det")" "detect reports the real branch, not 'HEAD' and not two lines"
assert_eq "1" "$(jq -r '.defaultBranch | split("\n") | length' <<<"$det")" "detect's defaultBranch is a single line"
assert_eq "true" "$(jq -r '.defaultBranch | test("^[A-Za-z0-9._/-]+$")' <<<"$det")" "detect's defaultBranch is a single token"
assert_eq "true" "$(jq -r '.git.root' <<<"$det")" "detect reports that the directory is the root of a git repository"
assert_eq "false" "$(jq -r '.git.hasCommits' <<<"$det")" "detect reports that the repository has no commits"
# Visibility is reported as visibility, not translated into a billing-plan verdict: a private
# repository on a paid plan supports branch protection perfectly well.
assert_eq "private" "$(jq -r .visibility <<<"$det")" "detect reports the repository visibility"
gl="$EVAL_TMP/gitlab"; unborn_repo "$gl" main https://gitlab.com/o/r.git
assert_eq "unknown" "$(jq -r .visibility <<<"$(bash "$DETECT" --repo-dir "$gl")")" "visibility stays 'unknown' when no GitHub repository answers, never a guess"

echo "-- init at tier 3 on an unborn repository"
out=$(bash "$RUN" --repo-dir "$u" --platform github --tier 3 --yes --no-deploy --verify 'npm run verify' 2>"$u.err"); rc=$?
assert_eq "0" "$rc" "tier 3 init on an unborn repository exits 0 ($(head -c 300 "$u.err"))"
assert_eq "main" "$(jq -r .repo.defaultBranch "$u/sdlc.config.json")" "repo.defaultBranch is the real branch"
assert_eq '["git push * main"]' "$(jq -c '.environments.prod.deployCommandPatterns' "$u/sdlc.config.json")" \
  "the production gate pattern names the branch, so a real push matches it"
assert_eq "0" "$(bash "$P/scripts/config/validate.sh" "$u/sdlc.config.json" --quiet; echo $?)" "the rendered config validates"
# Exact values, not a ban on the substring HEAD: a git instruction may legitimately contain it.
assert_match '^- \*\*Pull requests\*\*.*pr_create "<title>" <body-file> main <head-branch>' \
  "$(grep -F 'pr_create' "$u/docs/agents/issue-tracker.md")" "the tracker doc names the branch in pr_create"
assert_eq "1" "$(grep -cF 'merges to `main`' "$u/REVIEW.md")" "REVIEW.md names the branch exactly once"
assert_eq "1" "$(grep -cF 'every merge on `main`' "$u/CLAUDE.md")" "CLAUDE.md names the branch exactly once"
assert_eq "" "$(grep -rn 'HEAD$' "$u/sdlc.config.json" "$u/REVIEW.md" "$u/CLAUDE.md" "$u/docs/agents/issue-tracker.md" || true)" \
  "no rendered file ends a line with a bare HEAD (the two-line branch value)"
assert_not_match 'HEAD' "$(jq -r '.next_steps | join(" ")' <<<"$out")" "next_steps carry no HEAD"
py=$(eval_python) && for f in "$u"/.github/workflows/*.yml; do
  "$py" -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$f" 2>/dev/null \
    && _ok "rendered ${f##*/} parses as YAML" || _fail "rendered ${f##*/} does not parse as YAML" "$(head -c 200 "$f")"
done

echo "-- the fallback reads the real branch, it does not hardcode main"
t="$EVAL_TMP/trunk"; unborn_repo "$t" trunk https://github.com/mock-org/mock-repo.git
assert_eq "trunk" "$(jq -r .defaultBranch <<<"$(bash "$DETECT" --repo-dir "$t")")" "detect reports 'trunk' for git init -b trunk"
bash "$RUN" --repo-dir "$t" --platform github --tier 1 --yes --verify 'npm run verify' >/dev/null 2>&1
assert_eq "trunk" "$(jq -r .repo.defaultBranch "$t/sdlc.config.json")" "init records 'trunk' as the default branch"
assert_eq '["git push * trunk"]' "$(jq -c '.environments.prod.deployCommandPatterns' "$t/sdlc.config.json")" \
  "the production gate pattern names 'trunk'"

echo "-- a directory that is not a repository is reported, not guessed at"
n="$EVAL_TMP/notgit"; rm -rf "$n"; mkdir -p "$n"
det=$(bash "$DETECT" --repo-dir "$n"); rc=$?
assert_eq "0" "$rc" "detect.sh exits 0 outside a git repository"
assert_eq "false" "$(jq -r '.git.root' <<<"$det")" "detect reports git.root false: this directory is not a repository root"
# The scratch tree lives inside this repository, so git answers about the enclosing one. What
# matters is that git.root is false -- the exact condition run.sh refuses on -- and that the
# branch it reports is still a single valid token, never a two-line value.
assert_eq "true" "$(jq -r '.defaultBranch | test("^[A-Za-z0-9._/-]+$")' <<<"$det")" "detect's defaultBranch stays a single token outside a repository root"
out=$(bash "$RUN" --repo-dir "$n" 2>&1); rc=$?
assert_eq "1" "$rc" "run.sh still refuses a directory that is not a git repository"
assert_match 'not the root of a git repository' "$out" "run.sh names the condition"

echo "-- tier 3 refuses a verification command that verifies nothing"
v="$EVAL_TMP/noverify"; unborn_repo "$v" main https://github.com/mock-org/mock-repo.git
rm -f "$v/package.json"   # no candidate: detect falls back to the placeholder
det=$(bash "$DETECT" --repo-dir "$v")
placeholder=$(jq -r '.verifyCandidates[0]' <<<"$det")
assert_match 'set commands.verify' "$placeholder" "detect still proposes a placeholder when no candidate exists"
assert_eq "1" "$(bash -c "$placeholder" >/dev/null 2>&1; echo $?)" "the placeholder exits non-zero, so a verify job cannot go green on it"
out=$(bash "$RUN" --repo-dir "$v" --platform github --tier 3 --yes --no-deploy 2>&1); rc=$?
assert_eq "2" "$rc" "tier 3 without a real commands.verify is a usage error"
assert_match -- '--verify' "$out" "the error names the flag to pass"
assert_no_file "$v/sdlc.config.json" "the refused init wrote no config"
# A repository initialised by plugin 0.1.0 carries the old placeholder, which exits 0. Upgrading
# it to tier 3 must not hand the verification job a command that always succeeds.
legacy="$EVAL_TMP/legacy"; unborn_repo "$legacy" main https://github.com/mock-org/mock-repo.git
rm -f "$legacy/package.json"
bash "$RUN" --repo-dir "$legacy" --platform github --tier 1 --yes --verify "echo 'set commands.verify in sdlc.config.json'" >/dev/null 2>&1
out=$(bash "$RUN" --repo-dir "$legacy" --tier 3 --yes --no-deploy 2>&1); rc=$?
assert_eq "2" "$rc" "re-tiering a 0.1.0 repository to 3 with the old placeholder is a usage error too"

out=$(bash "$RUN" --repo-dir "$v" --platform github --tier 1 --yes 2>&1); rc=$?
assert_eq "0" "$rc" "tier 1 still initialises with the placeholder (${out:0:200})"

eval_done
