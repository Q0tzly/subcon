#!/bin/bash
# Run subcon's tests with a fake agy: tests/run.sh [group...]
# Groups: ticket submit query manage history stats resume (all when none given).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUBCON="$ROOT/bin/subcon"
FAKEBIN="$(mktemp -d)"
ln -s "$ROOT/tests/fake-agy" "$FAKEBIN/agy"
export PATH="$FAKEBIN:$PATH"
trap 'rm -rf "$FAKEBIN"' EXIT
unset SUBCON_MODEL FAKE_AGY_MODE FAKE_AGY_SLEEP FAKE_AGY_LOG
# Keep tests independent of the user's git config (and readable inside agy's sandbox).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# ---- helpers -------------------------------------------------------------

fail() { echo "    FAIL: $*" >&2; return 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-value}: expected [$2], got [$1]"; }
assert_match() { [[ "$1" =~ $2 ]] || fail "${3:-value}: [$1] does not match /$2/"; }
assert_rc() {
  # Explicit return: callers use `assert_rc || ...`, which turns off errexit in here.
  ! grep -q "not implemented" "$T/err" || { fail "not implemented: $(cat "$T/err")"; return 1; }
  [[ "$RC" -eq "$1" ]] || fail "exit code: expected $1, got $RC (stderr: $(head -c 400 "$T/err"))"
}

# sub <args>: run subcon, leaving stdout in OUT and the exit code in RC.
sub() { OUT="$("$SUBCON" "$@" 2>"$T/err")" && RC=0 || RC=$?; }
jget() { jq -r "$@" <<<"$OUT"; }

# write_ticket <path> <file>...: a minimal ticket listing <file>s under ## Files.
write_ticket() {
  local path=$1
  shift
  mkdir -p "$(dirname "$path")"
  {
    echo "# t"; echo; echo "## Goal"; echo "g"; echo; echo "## Files"
    local f
    for f in "$@"; do echo "- $f"; done
    echo; echo "## Acceptance"; echo '- `true`'
  } > "$path"
}

commit_all() { git add -A && git commit -qm "${1:-c}"; }

# Fresh repo in $REPO with README.md and committed ticket docs/t/01-a.md (Files: README.md).
setup() {
  T="$(mktemp -d)"
  export SUBCON_STATE="$T/state"
  REPO="$T/repo"
  git init -q "$REPO"
  cd "$REPO"
  git config user.name test
  git config user.email test@example.invalid
  echo base > README.md
  write_ticket docs/t/01-a.md README.md
  commit_all init
  TOP="$(git rev-parse --show-toplevel)"
}

pstree_of() {
  local p
  echo "$1"
  for p in $(pgrep -P "$1" 2>/dev/null); do pstree_of "$p"; done
}

# Collect the whole tree first, then kill it at once: killing children one by
# one lets a surviving parent react (write files) while the test cleans up.
killtree() {
  local pids
  pids="$(pstree_of "$1")"
  kill -9 $pids 2>/dev/null || true
}

teardown() {
  cd /
  local p
  for p in "$SUBCON_STATE"/jobs/*/pid; do
    [[ -f "$p" ]] && killtree "$(cat "$p")"
  done
  rm -rf "$T" 2>/dev/null || { sleep 0.5; rm -rf "$T"; }
}

jobdir() { echo "$SUBCON_STATE/jobs/$1"; }
jobcount() { find "$SUBCON_STATE/jobs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }
# result <id> [jq opts] <filter>
result() { local id=$1; shift; jq -r "$@" "$(jobdir "$id")/result.json"; }
worktrees() { git -C "$REPO" worktree list | wc -l | tr -d ' '; }

# wait_done <id>: poll (without cmd_wait) until the job has a result, up to 30s.
wait_done() {
  local i
  for ((i = 0; i < 300; i++)); do
    case "$(cat "$(jobdir "$1")/state" 2>/dev/null)" in
      finished|failed) [[ -f "$(jobdir "$1")/result.json" ]] && return 0 ;;
    esac
    sleep 0.1
  done
  fail "job $1 did not finish"
}

# wait_state <id> <state>: poll until state file says <state>, up to 10s.
wait_state() {
  local i
  for ((i = 0; i < 100; i++)); do
    [[ "$(cat "$(jobdir "$1")/state" 2>/dev/null)" == "$2" ]] && return 0
    sleep 0.1
  done
  fail "job $1 never reached $2"
}

submit_one() {
  sub submit "$@"
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
}

validate() {
  (
    export SUBCON_ROOT="$ROOT"
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/ticket.sh"
    ticket_validate "$1"
  ) >/dev/null 2>&1
}

# ---- ticket (03) ---------------------------------------------------------

test_ticket_new() {
  mkdir -p sub && cd sub
  sub new feat/01-parser
  assert_rc 0
  assert_eq "$OUT" '{"path":"docs/design/feat/01-parser.md"}' stdout
  local f="$TOP/docs/design/feat/01-parser.md"
  assert_eq "$(head -1 "$f")" "# 01-parser" title
  local h
  for h in Goal Files Interface Acceptance Notes; do
    grep -q "^## $h\$" "$f" || fail "missing ## $h"
  done
}

test_ticket_new_exists() {
  sub new feat/01-x
  echo keep >> docs/design/feat/01-x.md
  sub new feat/01-x
  assert_rc 1
  assert_eq "$(tail -1 docs/design/feat/01-x.md)" keep "file untouched"
}

test_ticket_new_bad_arg() {
  local a
  for a in x a/b/c "a b/c" "/x" "a/" "../a"; do
    sub new "$a"
    assert_rc 1 || fail "arg [$a]"
  done
  [[ ! -e docs/design ]] || fail "created docs/design"
}

test_ticket_guide() {
  cd "$T"
  sub guide
  assert_rc 0
  assert_eq "$OUT" "$(cat "$ROOT/docs/delegation.md")" guide
}

test_ticket_files() {
  cat > tk.md <<'EOF'
# x

## Files
- `a/b.sh`
* c.md
- d.txt  (new)

## Acceptance
- `make test`
EOF
  local got
  got="$(export SUBCON_ROOT="$ROOT"; source "$ROOT/lib/common.sh"; source "$ROOT/lib/ticket.sh"; ticket_files tk.md)"
  assert_eq "$got" "$(printf 'a/b.sh\nc.md\nd.txt')" files
}

test_ticket_validate_ok() {
  validate docs/t/01-a.md || fail "valid ticket rejected"
}

test_ticket_validate_uncommitted() {
  validate docs/t/01-a.md || fail "control: valid ticket rejected"
  write_ticket docs/t/02-b.md README.md
  ! validate docs/t/02-b.md || fail "untracked ticket accepted"
}

test_ticket_validate_modified() {
  validate docs/t/01-a.md || fail "control: valid ticket rejected"
  echo more >> docs/t/01-a.md
  ! validate docs/t/01-a.md || fail "modified ticket accepted"
}

test_ticket_validate_bad_files() {
  validate docs/t/01-a.md || fail "control: valid ticket rejected"
  local bad
  for bad in "" "/etc/passwd" "../x" "a/../b" "./a" "a/./b" "src/*.sh" "a?.md" "[ab].md"; do
    if [[ -z "$bad" ]]; then write_ticket docs/t/02-b.md; else write_ticket docs/t/02-b.md "$bad"; fi
    commit_all "bad $bad"
    ! validate docs/t/02-b.md || fail "accepted Files entry [$bad]"
  done
}

# ---- submit (04) ---------------------------------------------------------

test_submit_ok() {
  local head
  head="$(git rev-parse HEAD)"
  submit_one docs/t/01-a.md || return 1
  assert_match "$ID" '^[0-9]{8}-[0-9]{6}-01-a-[0-9a-f]{4}$' id
  assert_eq "$(jget '.[0].ticket')" docs/t/01-a.md ticket
  assert_eq "$(jget '.[0].error')" null error
  wait_done "$ID" || return 1
  local d
  d="$(jobdir "$ID")"
  assert_eq "$(result "$ID" .id)" "$ID" result.id
  assert_eq "$(result "$ID" .repo)" "$TOP" result.repo
  assert_eq "$(result "$ID" .ticket)" docs/t/01-a.md result.ticket
  assert_eq "$(result "$ID" .state)" finished state
  assert_eq "$(result "$ID" .status)" done status
  assert_eq "$(result "$ID" .checks.ok)" true checks.ok
  assert_eq "$(result "$ID" .checks.committed)" false committed
  assert_eq "$(result "$ID" -c .checks.outside_files)" '[]' outside
  assert_eq "$(result "$ID" -c .checks.files_changed)" '["README.md"]' files_changed
  assert_eq "$(result "$ID" .report.status)" done report
  assert_eq "$(result "$ID" .patch)" "$d/patch.diff" patch
  assert_eq "$(result "$ID" .error)" null error
  assert_match "$(result "$ID" .diffstat)" '1 file changed' diffstat
  grep -q '^+fake change$' "$d/patch.diff" || fail "patch lacks the change"
  assert_eq "$(cat "$d/state")" finished state-file
  assert_eq "$(jq -r .base "$d/meta.json")" "$head" meta.base
  assert_eq "$(jq -r .repo "$d/meta.json")" "$TOP" meta.repo
  assert_eq "$(jq -r .ticket "$d/meta.json")" docs/t/01-a.md meta.ticket
  assert_eq "$(jq -r .runner "$d/meta.json")" local meta.runner
  assert_eq "$(jq -r .model "$d/meta.json")" gemini-3.8-flash-medium meta.model
  assert_eq "$(jq -r .timeout "$d/meta.json")" 30m meta.timeout
  assert_match "$(jq -r .created_at "$d/meta.json")" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' meta.created_at
  cmp -s "$d/ticket.md" docs/t/01-a.md || fail "ticket.md differs"
  [[ -f "$d/agy.json" ]] || fail "no agy.json"
  [[ ! -e "$d/work" ]] || fail "work/ not removed"
  assert_eq "$(worktrees)" 1 worktrees
  assert_eq "$(cat README.md)" base "user tree untouched"
  assert_eq "$(git status --porcelain)" "" "user tree clean"
  assert_eq "$(git rev-parse HEAD)" "$head" "user HEAD"
}

test_submit_runner_args() {
  export FAKE_AGY_LOG="$T/agy.log"
  submit_one --model gemini-3.8-flash-high --timeout 5m docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  grep -qx "PWD=$(jobdir "$ID")/work" "$T/agy.log" || grep -qx "PWD=$(cd "$(jobdir "$ID")" && pwd -P)/work" "$T/agy.log" \
    || fail "agy not run in work/: $(cat "$T/agy.log")"
  grep -q -- '--model gemini-3.8-flash-high' "$T/agy.log" || fail "model not passed"
  grep -q -- '--print-timeout 5m' "$T/agy.log" || fail "timeout not passed"
  grep -q -- '--json-schema' "$T/agy.log" || fail "schema not passed"
  grep -q -- '--settings' "$T/agy.log" || fail "settings not passed"
  assert_eq "$(jq -r .model "$(jobdir "$ID")/meta.json")" gemini-3.8-flash-high meta.model
}

test_submit_returns_early() {
  export FAKE_AGY_MODE=sleep FAKE_AGY_SLEEP=3
  local start=$SECONDS
  submit_one docs/t/01-a.md || return 1
  (( SECONDS - start < 2 )) || fail "submit blocked for $((SECONDS - start))s"
  assert_match "$(cat "$(jobdir "$ID")/state")" '^(queued|running)$' state
  [[ -f "$(jobdir "$ID")/pid" ]] || fail "no pid file"
}

test_submit_uncommitted_ticket() {
  write_ticket docs/t/02-b.md README.md
  sub submit docs/t/02-b.md
  assert_rc 1
  assert_eq "$(jobcount)" 0 jobs
}

test_submit_one_invalid_creates_nothing() {
  write_ticket docs/t/02-b.md README.md
  sub submit docs/t/01-a.md docs/t/02-b.md
  assert_rc 1
  assert_eq "$(jobcount)" 0 jobs
}

test_submit_bad_args() {
  sub submit --runner nope docs/t/01-a.md
  assert_rc 1
  sub submit
  assert_rc 1
  sub submit --bogus docs/t/01-a.md
  assert_rc 1
  assert_eq "$(jobcount)" 0 jobs
}

test_submit_outside() {
  export FAKE_AGY_MODE=outside
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  assert_eq "$(result "$ID" .state)" finished state
  assert_eq "$(result "$ID" .checks.ok)" false ok
  assert_eq "$(result "$ID" -c .checks.outside_files)" '["outside.txt"]' outside
}

test_submit_commit() {
  export FAKE_AGY_MODE=commit
  local head
  head="$(git rev-parse HEAD)"
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  assert_eq "$(result "$ID" .checks.committed)" true committed
  assert_eq "$(result "$ID" .checks.ok)" false ok
  assert_eq "$(result "$ID" -c .checks.files_changed)" '["README.md"]' files_changed
  grep -q '^+fake change$' "$(jobdir "$ID")/patch.diff" || fail "committed change missing from patch"
  assert_eq "$(git rev-parse HEAD)" "$head" "user HEAD"
}

test_submit_partial() {
  export FAKE_AGY_MODE=partial
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  assert_eq "$(result "$ID" .state)" finished state
  assert_eq "$(result "$ID" .status)" partial status
  assert_eq "$(result "$ID" .checks.ok)" true ok
  assert_eq "$(result "$ID" -c .checks.files_changed)" '[]' files_changed
  assert_eq "$(result "$ID" .diffstat)" "" diffstat
  [[ "$(result "$ID" .patch)" != null ]] || fail "patch is null"
}

test_submit_fail() {
  export FAKE_AGY_MODE=fail
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  assert_eq "$(result "$ID" .state)" failed state
  assert_eq "$(cat "$(jobdir "$ID")/state")" failed state-file
  assert_match "$(result "$ID" .error)" '^runner exited with [1-9]' error
  assert_eq "$(result "$ID" .status)" null status
  assert_eq "$(result "$ID" .report)" null report
  [[ ! -e "$(jobdir "$ID")/work" ]] || fail "work/ not removed"
  assert_eq "$(worktrees)" 1 worktrees
}

test_submit_parallel() {
  export FAKE_AGY_MODE=sleep FAKE_AGY_SLEEP=2
  write_ticket docs/t/02-b.md other.txt
  commit_all b
  local start=$SECONDS
  sub submit docs/t/01-a.md docs/t/02-b.md
  assert_rc 0 || return 1
  local a b
  a="$(jget '.[0].id')"
  b="$(jget '.[1].id')"
  [[ "$a" != "$b" ]] || fail "same id"
  wait_done "$a" && wait_done "$b" || return 1
  (( SECONDS - start < 4 )) || fail "jobs did not run in parallel ($((SECONDS - start))s)"
  assert_eq "$(result "$b" -c .checks.files_changed)" '["other.txt"]' b.files
}

test_submit_dirty_tree() {
  echo dirty >> README.md
  submit_one docs/t/01-a.md || return 1
  grep -qi uncommitted "$T/err" || fail "no warning about uncommitted changes"
  wait_done "$ID" || return 1
  ! grep -q dirty "$(jobdir "$ID")/patch.diff" || fail "uncommitted change leaked into the job"
  assert_eq "$(tail -1 README.md)" dirty "user tree untouched"
}

# ---- query (05) ----------------------------------------------------------

test_query_run_ok() {
  sub run docs/t/01-a.md
  assert_rc 0
  assert_eq "$(jget type)" object type
  assert_eq "$(jget .state)" finished state
  assert_eq "$(jget .status)" done status
}

test_query_run_codes() {
  local mode want
  for mode in partial:2 outside:3 fail:4; do
    want="${mode#*:}"
    FAKE_AGY_MODE="${mode%%:*}" sub run docs/t/01-a.md
    assert_rc "$want" || fail "mode ${mode%%:*}"
  done
}

test_query_wait_many() {
  write_ticket docs/t/02-b.md other.txt
  commit_all b
  sub submit docs/t/01-a.md docs/t/02-b.md
  local a b
  a="$(jget '.[0].id')"
  b="$(jget '.[1].id')"
  sub wait "$a" "$b"
  assert_rc 0
  assert_eq "$(jget length)" 2 length
  assert_eq "$(jget '[.[].state] | unique | join(",")')" finished states
  assert_eq "$(jget '.[0].id')" "$a" order
}

test_query_wait_mixed_codes() {
  submit_one docs/t/01-a.md || return 1
  local a=$ID
  FAKE_AGY_MODE=outside submit_one docs/t/01-a.md || return 1
  sub wait "$a" "$ID"
  assert_rc 3
}

test_query_wait_timeout() {
  export FAKE_AGY_MODE=sleep FAKE_AGY_SLEEP=6
  submit_one docs/t/01-a.md || return 1
  local start=$SECONDS
  sub wait --timeout 1 "$ID"
  assert_rc 5
  (( SECONDS - start < 4 )) || fail "wait ignored its timeout"
  assert_match "$(jget '.[0].state')" '^(queued|running)$' state
  assert_eq "$(jget '.[0].status')" null status
  assert_eq "$(jget '.[0].ticket')" docs/t/01-a.md ticket
}

test_query_show_running() {
  export FAKE_AGY_MODE=sleep FAKE_AGY_SLEEP=6
  submit_one docs/t/01-a.md || return 1
  sub show "$ID"
  assert_rc 0
  assert_match "$(jget .state)" '^(queued|running)$' state
  assert_eq "$(jget .checks)" null checks
  assert_eq "$(jget .id)" "$ID" id
}

test_query_show_finished() {
  export FAKE_AGY_MODE=outside
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub show "$ID"
  assert_rc 3
  assert_eq "$(jq -S . <<<"$OUT")" "$(jq -S . "$(jobdir "$ID")/result.json")" show
}

test_query_unknown_id() {
  sub show nope
  assert_rc 1
  submit_one docs/t/01-a.md || return 1
  sub wait "$ID" nope
  assert_rc 1
}

test_query_runner_died() {
  export FAKE_AGY_MODE=sleep FAKE_AGY_SLEEP=30
  submit_one docs/t/01-a.md || return 1
  wait_state "$ID" running || return 1
  killtree "$(cat "$(jobdir "$ID")/pid")"
  sub show "$ID"
  assert_rc 4
  assert_eq "$(jget .state)" failed state
  assert_eq "$(jget .error)" "runner died" error
  assert_eq "$(cat "$(jobdir "$ID")/state")" failed state-file
  [[ ! -e "$(jobdir "$ID")/work" ]] || fail "work/ not removed"
  assert_eq "$(worktrees)" 1 worktrees
}

# ---- manage (06) ---------------------------------------------------------

# Two finished jobs: A (older) and B.
two_jobs() {
  submit_one docs/t/01-a.md || return 1
  A=$ID
  sleep 1.1
  submit_one docs/t/01-a.md || return 1
  B=$ID
  wait_done "$A" && wait_done "$B"
}

other_repo() {
  OTHER="$T/other"
  git init -q "$OTHER"
  cd "$OTHER"
  git config user.name test
  git config user.email test@example.invalid
  echo o > o.txt
  commit_all o
}

test_manage_list() {
  two_jobs || return 1
  sub list
  assert_rc 0
  assert_eq "$(jget length)" 2 length
  assert_eq "$(jget '.[0].id')" "$B" newest-first
  assert_eq "$(jget '.[0] | keys | join(",")')" created_at,id,repo,state,status,ticket keys
  assert_eq "$(jget '.[0].status')" done status
}

test_manage_list_scopes() {
  two_jobs || return 1
  other_repo
  sub list
  assert_rc 0
  assert_eq "$OUT" "[]" other-repo
  sub list --all
  assert_eq "$(jget length)" 2 all
}

test_manage_diff() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub diff "$ID"
  assert_rc 0
  assert_eq "$OUT" "$(cat "$(jobdir "$ID")/patch.diff")" diff
  sub diff nope
  assert_rc 1
}

test_manage_apply() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub apply "$ID"
  assert_rc 0
  assert_eq "$OUT" "{\"id\":\"$ID\",\"applied\":true}" stdout
  assert_eq "$(cat README.md)" "$(printf 'base\nfake change')" applied
  assert_eq "$(git diff --cached --name-only)" "" "index untouched"
}

test_manage_apply_from_subdir() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  mkdir -p sub && cd sub
  sub apply "$ID"
  assert_rc 0
  assert_eq "$(cat ../README.md)" "$(printf 'base\nfake change')" applied
}

test_manage_apply_conflict() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  echo changed > README.md
  sub apply "$ID"
  assert_rc 1
  assert_eq "$(cat README.md)" changed "tree untouched"
  [[ -z "$(find . -name '*.rej' -o -name '*.orig')" ]] || fail "left reject files"
}

test_manage_apply_other_repo() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  other_repo
  sub apply "$ID"
  assert_rc 1
  assert_eq "$(git status --porcelain)" "" "other repo untouched"
}

test_manage_discard() {
  two_jobs || return 1
  sub discard "$A" "$B"
  assert_rc 0
  assert_eq "$(jget -c .discarded)" "[\"$A\",\"$B\"]" stdout
  assert_eq "$(jobcount)" 0 jobs
}

test_manage_discard_unknown() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub discard "$ID" nope
  assert_rc 1
  [[ -d "$(jobdir "$ID")" ]] || fail "removed a job despite the unknown id"
}

test_manage_discard_running() {
  export FAKE_AGY_MODE=sleep FAKE_AGY_SLEEP=30
  submit_one docs/t/01-a.md || return 1
  wait_state "$ID" running || return 1
  local pid
  pid="$(cat "$(jobdir "$ID")/pid")"
  sub discard "$ID"
  assert_rc 0
  [[ ! -e "$(jobdir "$ID")" ]] || fail "job dir remains"
  ! kill -0 "$pid" 2>/dev/null || fail "runner still alive"
  assert_eq "$(worktrees)" 1 worktrees
}

# ---- history (10) --------------------------------------------------------

hist() { echo "$SUBCON_STATE/history.jsonl"; }
hline() { sed -n "${1}p" "$(hist)"; }

test_history_job_line() {
  sub run docs/t/01-a.md
  assert_rc 0 || return 1
  local id
  id="$(jget .id)"
  [[ -f "$(hist)" ]] || fail "no history.jsonl"
  assert_eq "$(wc -l < "$(hist)" | tr -d ' ')" 1 lines
  local l
  l="$(hline 1)"
  assert_eq "$(jq -r .type <<<"$l")" job type
  assert_eq "$(jq -r .id <<<"$l")" "$id" id
  assert_eq "$(jq -r .repo <<<"$l")" "$TOP" repo
  assert_eq "$(jq -r .ticket <<<"$l")" docs/t/01-a.md ticket
  assert_eq "$(jq -r .model <<<"$l")" gemini-3.8-flash-medium model
  assert_eq "$(jq -r .runner <<<"$l")" local runner
  assert_eq "$(jq -r .created_at <<<"$l")" "$(jq -r .created_at "$(jobdir "$id")/meta.json")" created_at
  assert_match "$(jq -r .finished_at <<<"$l")" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' finished_at
  assert_eq "$(jq -r .state <<<"$l")" finished state
  assert_eq "$(jq -r .status <<<"$l")" done status
  assert_eq "$(jq -r .checks_ok <<<"$l")" true checks_ok
  assert_eq "$(jq -r .files_changed <<<"$l")" 1 files_changed
  assert_eq "$(jq -r .insertions <<<"$l")" 1 insertions
  assert_eq "$(jq -r .deletions <<<"$l")" 0 deletions
  assert_eq "$(jq -r .duration_s <<<"$l")" 1.5 duration_s
  assert_eq "$(jq -c .tokens <<<"$l")" '{"input":100,"output":20,"total":120}' tokens
  assert_eq "$(jq -r .resume_of <<<"$l")" null resume_of
}

test_history_failed_job() {
  FAKE_AGY_MODE=fail sub run docs/t/01-a.md
  assert_rc 4 || return 1
  local l
  l="$(hline 1)"
  assert_eq "$(jq -r .state <<<"$l")" failed state
  assert_eq "$(jq -r .status <<<"$l")" null status
  assert_eq "$(jq -r .duration_s <<<"$l")" null duration_s
  assert_eq "$(jq -r .tokens <<<"$l")" null tokens
}

test_history_partial_no_patch_counts() {
  FAKE_AGY_MODE=partial sub run docs/t/01-a.md
  assert_rc 2 || return 1
  local l
  l="$(hline 1)"
  assert_eq "$(jq -r .files_changed <<<"$l")" 0 files_changed
  assert_eq "$(jq -r .insertions <<<"$l")" 0 insertions
  assert_eq "$(jq -r .deletions <<<"$l")" 0 deletions
}

test_history_survives_discard() {
  sub run docs/t/01-a.md
  local id
  id="$(jget .id)"
  sub discard "$id"
  assert_rc 0 || return 1
  assert_eq "$(jq -r .id "$(hist)")" "$id" "line kept"
}

test_history_applied_event() {
  sub run docs/t/01-a.md
  local id
  id="$(jget .id)"
  sub apply "$id"
  assert_rc 0 || return 1
  assert_eq "$(wc -l < "$(hist)" | tr -d ' ')" 2 lines
  local l
  l="$(hline 2)"
  assert_eq "$(jq -c '{type, id, event}' <<<"$l")" "{\"type\":\"event\",\"id\":\"$id\",\"event\":\"applied\"}" event
  assert_match "$(jq -r .at <<<"$l")" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' at
}

test_history_failed_apply_no_event() {
  sub run docs/t/01-a.md
  local id
  id="$(jget .id)"
  echo changed > README.md
  sub apply "$id"
  assert_rc 1 || return 1
  assert_eq "$(wc -l < "$(hist)" | tr -d ' ')" 1 "no event line"
}

test_history_stale_lock() {
  mkdir -p "$SUBCON_STATE/history.jsonl.lock"
  touch -t 202001010000 "$SUBCON_STATE/history.jsonl.lock"
  sub run docs/t/01-a.md
  assert_rc 0 || return 1
  assert_eq "$(wc -l < "$(hist)" | tr -d ' ')" 1 "line written past a stale lock"
  [[ ! -e "$SUBCON_STATE/history.jsonl.lock" ]] || fail "lock left behind"
}

test_history_parallel() {
  export FAKE_AGY_MODE=sleep FAKE_AGY_SLEEP=1
  write_ticket docs/t/02-b.md b.txt
  write_ticket docs/t/03-c.md c.txt
  commit_all bc
  sub submit docs/t/01-a.md docs/t/02-b.md docs/t/03-c.md
  assert_rc 0 || return 1
  sub wait $(jget -r '.[].id')
  assert_rc 0 || return 1
  assert_eq "$(wc -l < "$(hist)" | tr -d ' ')" 3 lines
  jq -c . "$(hist)" >/dev/null || fail "history has a broken line"
  assert_eq "$(jq -r .id "$(hist)" | sort -u | wc -l | tr -d ' ')" 3 "distinct ids"
}

# ---- stats (11) ----------------------------------------------------------

# hjob <id> <repo> <model> <state> <status|null> <checks_ok|null> <duration|null> <tin|null> <tout|null> [days-ago]
hjob() {
  local created
  created="$(date -u -r $(( $(date +%s) - ${10:-0} * 86400 )) +%Y-%m-%dT%H:%M:%SZ)"
  jq -cn --arg id "$1" --arg repo "$2" --arg model "$3" --arg state "$4" --arg created "$created" \
    --argjson status "$( [[ $5 == null ]] && echo null || echo "\"$5\"")" \
    --argjson ok "$6" --argjson dur "$7" --argjson tin "$8" --argjson tout "$9" '
    {type: "job", id: $id, repo: $repo, ticket: "docs/t/x.md", model: $model, runner: "local",
     created_at: $created, finished_at: $created, duration_s: $dur, state: $state, status: $status,
     checks_ok: $ok, files_changed: 1, insertions: 1, deletions: 0,
     tokens: (if $tin == null then null else {input: $tin, output: $tout, total: ($tin + $tout)} end),
     resume_of: null}' >> "$(hist)"
}
hevent() { jq -cn --arg id "$1" '{type: "event", id: $id, event: "applied", at: "2026-01-01T00:00:00Z"}' >> "$(hist)"; }

# A: done/ok m1, B: partial m1, C: failed m2, D: done but checks failed m2, E: other repo, A and D applied (A twice).
sample_history() {
  mkdir -p "$SUBCON_STATE"
  hjob A "$TOP" m1 finished done true 10 80 20
  hjob B "$TOP" m1 finished partial true 20 40 10
  hjob C "$TOP" m2 failed null null null null null
  hjob D "$TOP" m2 finished done false 30 8 2
  hjob E /elsewhere m1 finished done true 5 1 1
  hevent A
  hevent A
  hevent D
}

test_stats_empty() {
  sub stats
  assert_rc 0 || return 1
  assert_eq "$(jget .jobs)" 0 jobs
  assert_eq "$(jget .scope)" repo scope
  assert_eq "$(jget .repo)" "$TOP" repo
  assert_eq "$(jget .success_rate)" null success_rate
  assert_eq "$(jget .apply_rate)" null apply_rate
  assert_eq "$(jget -c .by_model)" '{}' by_model
}

test_stats_counts() {
  sample_history
  sub stats
  assert_rc 0 || return 1
  assert_eq "$(jget .jobs)" 4 jobs
  assert_eq "$(jget -c .by_state)" '{"finished":3,"failed":1}' by_state
  assert_eq "$(jget -c .by_status)" '{"done":2,"partial":1,"blocked":0,"none":1}' by_status
  assert_eq "$(jget .success)" 1 success
  assert_eq "$(jget .success_rate)" 0.25 success_rate
  assert_eq "$(jget .applied)" 2 applied
  assert_eq "$(jget .apply_rate)" 0.5 apply_rate
  assert_eq "$(jget -c .duration_s)" '{"total":60,"median":20}' duration
  assert_eq "$(jget -c .tokens)" '{"input":128,"output":32,"total":160}' tokens
  assert_eq "$(jget -c .by_model.m1)" '{"jobs":2,"success":1,"applied":1,"tokens_total":150}' m1
  assert_eq "$(jget -c .by_model.m2)" '{"jobs":2,"success":0,"applied":1,"tokens_total":10}' m2
}

test_stats_all() {
  sample_history
  sub stats --all
  assert_rc 0 || return 1
  assert_eq "$(jget .scope)" all scope
  assert_eq "$(jget .repo)" null repo
  assert_eq "$(jget .jobs)" 5 jobs
  assert_eq "$(jget .by_model.m1.jobs)" 3 m1
}

test_stats_median_even() {
  mkdir -p "$SUBCON_STATE"
  hjob A "$TOP" m1 finished done true 10 1 1
  hjob B "$TOP" m1 finished done true 30 1 1
  sub stats
  assert_eq "$(jget .duration_s.median)" 20 median
}

test_stats_since() {
  mkdir -p "$SUBCON_STATE"
  hjob OLD "$TOP" m1 finished done true 10 1 1 10
  hjob NEW "$TOP" m1 finished done true 10 1 1 0
  sub stats --since 7d
  assert_rc 0 || return 1
  assert_eq "$(jget .jobs)" 1 7d
  assert_eq "$(jget .since)" 7d since
  sub stats --since 2h
  assert_eq "$(jget .jobs)" 1 2h
  sub stats
  assert_eq "$(jget .jobs)" 2 none
  assert_eq "$(jget .since)" null since-null
}

test_stats_bad_args() {
  local a
  for a in 7x abc 7 d -1d; do
    sub stats --since "$a"
    assert_rc 1 || fail "accepted --since $a"
  done
  sub stats --bogus
  assert_rc 1
}

test_stats_text() {
  sample_history
  sub stats --text
  assert_rc 0 || return 1
  grep -q '^Jobs:' <<<"$OUT" || fail "no Jobs: line"
  grep -q 'm1' <<<"$OUT" || fail "no model row"
  ! jq -e . >/dev/null 2>&1 <<<"$OUT" || fail "--text printed JSON"
}

test_stats_real_jobs() {
  sub run docs/t/01-a.md
  local id
  id="$(jget .id)"
  sub apply "$id"
  FAKE_AGY_MODE=partial sub run docs/t/01-a.md
  sub stats
  assert_rc 0 || return 1
  assert_eq "$(jget .jobs)" 2 jobs
  assert_eq "$(jget .success)" 1 success
  assert_eq "$(jget .applied)" 1 applied
  assert_eq "$(jget .tokens.total)" 240 tokens
}

# ---- resume (08) ---------------------------------------------------------

# failed_job: a job that died mid-work with a conversation id.
failed_job() {
  FAKE_AGY_MODE=error submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
}

test_resume_records_conversation() {
  failed_job || return 1
  assert_eq "$(result "$ID" .state)" failed state
  assert_eq "$(result "$ID" .conversation)" conv-fake-1 conversation
  assert_eq "$(result "$ID" .agy_error)" "fake network error" agy_error
  [[ -s "$(jobdir "$ID")/patch.diff" ]] || fail "partial work not kept in patch.diff"
}

test_resume_finished_has_conversation() {
  sub run docs/t/01-a.md
  assert_rc 0 || return 1
  assert_eq "$(jget .conversation)" conv-fake-1 conversation
  assert_eq "$(jget .agy_error)" null agy_error
}

test_resume_no_conversation_when_agy_silent() {
  FAKE_AGY_MODE=error_noconv submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  assert_eq "$(result "$ID" .conversation)" null conversation
  assert_eq "$(result "$ID" .agy_error)" null agy_error
}

test_resume_after_kill() {
  FAKE_AGY_MODE=killed submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  assert_eq "$(result "$ID" .state)" failed state
  assert_eq "$(result "$ID" .conversation)" conv-fake-1 conversation
  assert_match "$(result "$ID" .agy_error)" 'without a result' agy_error
  sub resume "$ID"
  assert_rc 0 || return 1
  wait_done "$(jget '.[0].id')" || return 1
  assert_eq "$(result "$(jget '.[0].id')" .state)" finished state
}

test_resume_ok() {
  failed_job || return 1
  local old=$ID log="$T/agy.log"
  FAKE_AGY_LOG="$log" sub resume "$old"
  assert_rc 0 || return 1
  local new
  new="$(jget '.[0].id')"
  assert_match "$new" '.' new-id
  [[ "$new" != "$old" ]] || fail "resume reused the id"
  assert_eq "$(jget '.[0].error')" null error
  wait_done "$new" || return 1
  assert_eq "$(result "$new" .state)" finished state
  assert_eq "$(result "$new" .status)" done status
  assert_eq "$(jq -r .resume_of "$(jobdir "$new")/meta.json")" "$old" resume_of
  assert_eq "$(jq -r .base "$(jobdir "$new")/meta.json")" "$(jq -r .base "$(jobdir "$old")/meta.json")" base
  assert_eq "$(jq -r .ticket "$(jobdir "$new")/meta.json")" docs/t/01-a.md ticket
  grep -q -- "--conversation conv-fake-1" "$log" || fail "no --conversation: $(cat "$log")"
  grep -qi "interrupted" "$(jobdir "$new")/prompt.txt" || fail "no resume prompt"
  # The old patch is carried over: the interrupted run's line plus the new one.
  assert_eq "$(git apply --stat "$(jobdir "$new")/patch.diff" | tail -1 | grep -o '[0-9]* insertion')" "2 insertion" carried-patch
  assert_eq "$(worktrees)" 1 worktrees
  assert_eq "$(result "$old" .state)" failed old-state
}

test_resume_chain() {
  failed_job || return 1
  FAKE_AGY_MODE=error sub resume "$ID"
  assert_rc 0 || return 1
  local second
  second="$(jget '.[0].id')"
  wait_done "$second" || return 1
  assert_eq "$(result "$second" .state)" failed state
  sub resume "$second"
  assert_rc 0 || return 1
  wait_done "$(jget '.[0].id')" || return 1
  assert_eq "$(result "$(jget '.[0].id')" .state)" finished state
}

test_resume_not_resumable() {
  sub run docs/t/01-a.md
  local done_id
  done_id="$(jget .id)"
  sub resume "$done_id"
  assert_rc 1 || return 1
  FAKE_AGY_MODE=error_noconv submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub resume "$ID"
  assert_rc 1 || return 1
  sub resume no-such-job
  assert_rc 1 || return 1
  sub resume
  assert_rc 1 || return 1
  assert_eq "$(jobcount)" 2 "no job created"
}

test_resume_history() {
  failed_job || return 1
  sub resume "$ID"
  local new
  new="$(jget '.[0].id')"
  wait_done "$new" || return 1
  assert_eq "$(jq -r --arg id "$new" 'select(.type == "job" and .id == $id) | .resume_of' "$SUBCON_STATE/history.jsonl")" "$ID" resume_of
}

# ---- runner --------------------------------------------------------------

groups=("$@")
[[ ${#groups[@]} -gt 0 ]] || groups=(ticket submit query manage history stats resume)

pass=0 failed=()
for g in "${groups[@]}"; do
  tests="$(declare -F | awk -v p="test_${g}_" '$3 ~ "^" p { print $3 }')"
  [[ -n "$tests" ]] || { echo "unknown group: $g" >&2; exit 1; }
  for t in $tests; do
    # Not inside `if`: errexit is ignored there, and failed asserts must stop the test.
    ( set -e; setup; trap teardown EXIT; "$t" ) 2>"${TMPDIR:-/tmp}/subcon-test.$$"
    if [[ $? -eq 0 ]]; then
      pass=$((pass + 1))
      echo "ok   $t"
    else
      failed+=("$t")
      echo "FAIL $t"
      sed 's/^/     /' "${TMPDIR:-/tmp}/subcon-test.$$"
    fi
  done
done
rm -f "${TMPDIR:-/tmp}/subcon-test.$$"

echo "$pass passed, ${#failed[@]} failed"
[[ ${#failed[@]} -eq 0 ]]
