#!/usr/bin/env bash
# packet.sh — build a Review Packet for spec-review.
#
# Usage (run inside the repo under review):
#   packet.sh BASE [HEAD] [--spec FILE] [--pr N] [--test-cmd "go test ./..."] [--out DIR]
#
# BASE/HEAD are git refs; diff is BASE...HEAD (merge-base). --pr N fetches the PR body via gh as
# the spec when --spec is absent. Output: DIR/packet.md (default .review/<short-head>/packet.md).
# Prints the packet path on stdout.

set -euo pipefail

base="${1:-}"; [ -z "$base" ] && { echo "usage: packet.sh BASE [HEAD] [--spec FILE] [--pr N] [--test-cmd CMD] [--out DIR] [-- PATHSPEC...]" >&2; exit 2; }
shift
head="HEAD"
if [ $# -gt 0 ] && [[ "$1" != --* ]]; then head="$1"; shift; fi

spec_file=""; pr=""; test_cmd=""; out=""; force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --spec) spec_file="$2"; shift 2;;
    --pr) pr="$2"; shift 2;;
    --test-cmd) test_cmd="$2"; shift 2;;
    --out) out="$2"; shift 2;;
    --force) force=1; shift;;
    --) shift; break;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
# Remaining args are git pathspecs. Lockfiles and generated bundles are always excluded.
paths=("$@" ':(exclude,glob)**/pnpm-lock.yaml' ':(exclude,glob)**/package-lock.json' ':(exclude,glob)**/yarn.lock' ':(exclude,glob)**/go.sum' ':(exclude,glob)**/*.min.*')

git rev-parse --verify -q "$base" >/dev/null || { echo "bad base ref: $base" >&2; exit 1; }
git rev-parse --verify -q "$head" >/dev/null || { echo "bad head ref: $head" >&2; exit 1; }
range="$base...$head"
if [ -z "$(git diff --stat "$range" -- "${paths[@]}")" ]; then echo "empty diff for $range" >&2; exit 1; fi

tag=$(git rev-parse --short "$head")
[ -z "$out" ] && out=".review/$tag"
mkdir -p "$out"
packet="$out/packet.md"

# One detached worktree per review session, pinned to the head the diff was produced against.
# Keep the lock until bench.sh save/drop: a second packet build must not remove a worktree
# that active reviewers may still be reading.
lock="$out/.session.lock"
acquire_lock() {
  if mkdir "$lock" 2>/dev/null; then
    return 0
  fi
  local owner_file="$lock/owner"
  if [ -f "$owner_file" ]; then
    local lock_pid lock_started now age
    lock_pid=$(sed -n 's/^pid=//p' "$owner_file" | head -1)
    lock_started=$(sed -n 's/^epoch=//p' "$owner_file" | head -1)
    now=$(date +%s)
    age=$(( now - ${lock_started:-now} ))

    # Stale heuristics:
    # 1. Force requested: always override
    # 2. Hard TTL: older than 8 hours (28800s)
    # 3. Soft TTL: older than 2 hours (7200s) AND parent pid is dead
    local is_stale=0
    if [ "$force" -eq 1 ]; then
      is_stale=1
    elif [ "$age" -ge 28800 ]; then
      is_stale=1
    elif [ "$age" -ge 7200 ]; then
      if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
        is_stale=1
      fi
    fi

    if [ "$is_stale" -eq 1 ]; then
      echo "recovering stale review session at $out (age: ${age}s, owner pid: ${lock_pid:-unknown})..." >&2
      local old_wt="$out/worktree"
      if [ -d "$old_wt" ]; then
        if [ "$force" -ne 1 ] && [ -n "$(git -C "$old_wt" status --porcelain 2>/dev/null)" ]; then
          echo "error: stale worktree at $old_wt has uncommitted changes! Aborting recovery to prevent data loss. Use --force or bench.sh drop to clean." >&2
          exit 1
        fi
        git worktree remove --force "$old_wt" >/dev/null 2>&1 || rm -rf "$old_wt"
      fi
      rm -rf "$lock"
      if mkdir "$lock" 2>/dev/null; then
        return 0
      fi
    fi
  fi
  echo "review session already active at $out; run bench.sh drop $out before rebuilding (or pass --force)" >&2
  exit 1
}
acquire_lock
printf 'pid=%s\nhead=%s\nstarted=%s\nepoch=%s\n' "${PPID:-$$}" "$(git rev-parse "$head")" "$(date -u +%FT%TZ)" "$(date +%s)" > "$lock/owner"
wt="$out/worktree"
cleanup_on_error() {
  status=$?
  if [ "$status" -ne 0 ]; then
    [ -d "$wt" ] && git worktree remove --force "$wt" >/dev/null 2>&1 || true
    rm -rf "$lock"
  fi
  exit "$status"
}
trap cleanup_on_error EXIT
[ ! -e "$wt" ] || { echo "unexpected existing worktree at $wt; run bench.sh drop $out" >&2; exit 1; }
git worktree add --detach --quiet "$wt" "$head"

{
  echo "# Review Packet"
  echo
  echo "repo: $(basename "$(git rev-parse --show-toplevel)")  range: $range  head: $(git rev-parse "$head")"
  echo
  echo "## Spec"
  echo
  if [ -n "$spec_file" ]; then
    cat "$spec_file"
  elif [ -n "$pr" ]; then
    gh pr view "$pr" --json title,body --template '{{.title}}{{"\n\n"}}{{.body}}'
  else
    echo "(no spec supplied; commit messages below are the only statement of intent)"
  fi
  echo
  echo "## Acceptance Criteria"
  echo
  echo "Derive AC-n from the Spec section above. If the spec does not state acceptance criteria, treat each declared behavior change as one AC and cite the spec line."
  echo
  echo "## Commits"
  echo
  git log --format='- %h %s' "$base..$head"
  echo
  echo "## Changed files (whole range)"
  echo
  git diff --stat "$range"
  echo
  if [ $# -gt 0 ]; then
    echo "## Review scope"
    echo
    echo "Only the following pathspecs are included in the diff below; other changes are out of scope for this review: $*"
    echo
  fi
  echo "## Diff"
  echo
  echo '```diff'
  git diff "$range" -- "${paths[@]}"
  echo '```'
  echo
  echo "## Tests touched or adjacent"
  echo
  # test files in the same directories as changed files
  git diff --name-only "$range" -- "${paths[@]}" | xargs -n1 dirname | sort -u | while read -r d; do
    git ls-files "$d" 2>/dev/null | { grep -E '(_test\.go|\.test\.[jt]sx?|\.spec\.[jt]sx?)$' || true; }
  done | sort -u | sed 's/^/- /'
  echo
  echo "## Test result"
  echo
  if [ -n "$test_cmd" ]; then
    echo "command: $test_cmd"
    echo '```'
    test_log=$(mktemp)
    test_status=0
    (cd "$wt" && bash -c "$test_cmd") >"$test_log" 2>&1 || test_status=$?
    tail -n 80 "$test_log"
    rm -f "$test_log"
    echo '```'
    echo "exit: $test_status"
  else
    echo "(not run)"
  fi
} > "$packet"



trap - EXIT
echo "$packet"
