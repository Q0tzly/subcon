#!/bin/bash
# Run subcon's tests with a fake agy: tests/run.sh [group...]
# Groups: ticket submit query manage (all when none given).
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
jget() { jq -r "$1" <<<"$OUT"; }

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

killtree() {
  local p
  for p in $(pgrep -P "$1" 2>/dev/null); do killtree "$p"; done
  kill -9 "$1" 2>/dev/null || true
}

teardown() {
  cd /
  local p
  for p in "$SUBCON_STATE"/jobs/*/pid; do
    [[ -f "$p" ]] && killtree "$(cat "$p")"
  done
  rm -rf "$T"
}

jobdir() { echo "$SUBCON_STATE/jobs/$1"; }
jobcount() { find "$SUBCON_STATE/jobs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }
result() { jq -r "$2" "$(jobdir "$1")/result.json"; }
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

# ---- runner --------------------------------------------------------------

groups=("$@")
[[ ${#groups[@]} -gt 0 ]] || groups=(ticket submit query manage)

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
