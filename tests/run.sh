#!/bin/bash
# Run subcon's tests with a fake agy: tests/run.sh [group...]
# Groups: ticket submit query manage commit checks reject formats runnerenv entry guard logcmd history stats export resume preflight authwarn container containerpre cijob cirunner cipre driver budget (all when none given).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUBCON="$ROOT/bin/subcon"
FAKEBIN="$(mktemp -d)"
ln -s "$ROOT/tests/fake-agy" "$FAKEBIN/agy"
ln -s "$ROOT/drivers/agy" "$FAKEBIN/subcon-driver-agy"
ln -s "$ROOT/drivers/claude" "$FAKEBIN/subcon-driver-claude"
export PATH="$FAKEBIN:$PATH"
trap 'rm -rf "$FAKEBIN"' EXIT
unset SUBCON_MODEL SUBCON_DRIVER SUBCON_JOB_MODEL FAKE_AGY_MODE FAKE_AGY_SLEEP FAKE_AGY_LOG SUBCON_NO_AUTH_WARNING SUBCON_REVIEWER SUBCON_BUDGET_TOKENS SUBCON_BUDGET_JOBS
unset GEMINI_API_KEY ANTHROPIC_API_KEY SUBCON_CONTAINER_ENGINE SUBCON_CONTAINER_IMAGE FAKE_ENGINE_LOG FAKE_ENGINE_ENTRY FAKE_ENGINE_NO_IMAGE FAKE_GH_STATE FAKE_GH_CONCLUSION FAKE_GH_WORKSPACE FAKE_GH_SUBCON_ROOT SUBCON_CI_POLL FAKE_GH_NO_AUTH FAKE_GH_FOREIGN_OWNER
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

# clean_path: PATH without the fake-agy dir and without $HOME/.local/bin,
# so a test can simulate "agy is not on PATH" and control $HOME freely.
clean_path() {
  local p=":$PATH:"
  p="${p//:$FAKEBIN:/:}"
  p="${p//:$HOME/.local/bin:/:}"
  p="${p#:}"
  p="${p%:}"
  printf '%s' "$p"
}

# preflight_home <with-agy|no-agy|with-claude|with-opencode>: a throwaway
# HOME; with-agy puts the fake agy at $HOME/.local/bin/agy (and nowhere on
# PATH); with-claude does the same for the fake claude; with-opencode puts
# the fake opencode at $HOME/.opencode/bin/opencode.
preflight_home() {
  local h="$T/home-$1"
  mkdir -p "$h"
  if [[ "$1" == with-agy ]]; then
    mkdir -p "$h/.local/bin"
    ln -s "$ROOT/tests/fake-agy" "$h/.local/bin/agy"
  fi
  if [[ "$1" == with-claude ]]; then
    mkdir -p "$h/.local/bin"
    ln -s "$ROOT/tests/fake-claude" "$h/.local/bin/claude"
  fi
  if [[ "$1" == with-opencode ]]; then
    mkdir -p "$h/.opencode/bin"
    ln -s "$ROOT/tests/fake-opencode" "$h/.opencode/bin/opencode"
  fi
  printf '%s' "$h"
}

# auth_home <consumer|api-key>: a throwaway HOME whose agy settings mark the
# auth mode: api-key writes {"modelProvider":"gemini"}; consumer writes none.
auth_home() {
  local h="$T/home-auth-$1"
  mkdir -p "$h"
  if [[ "$1" == api-key ]]; then
    mkdir -p "$h/.gemini/antigravity-cli"
    echo '{"modelProvider":"gemini"}' > "$h/.gemini/antigravity-cli/settings.json"
  fi
  printf '%s' "$h"
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

test_submit_driver_meta() {
  export FAKE_AGY_MODE=ok
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  local d
  d="$(jobdir "$ID")"
  assert_eq "$(jq -r .driver "$d/meta.json")" agy meta.driver
  assert_eq "$(result "$ID" .status)" done status
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

test_submit_overlap_warn_active() {
  write_ticket docs/t/02-b.md lib/x.txt
  write_ticket docs/t/03-c.md lib/x.txt lib/y.txt
  commit_all overlap-tickets
  export FAKE_AGY_MODE=sleep FAKE_AGY_SLEEP=3
  sub submit docs/t/02-b.md
  assert_rc 0 || return 1
  local a b
  a="$(jget '.[0].id')"
  sub submit docs/t/03-c.md
  assert_rc 0 || return 1
  b="$(jget '.[0].id')"
  grep -q "overlaps with active job $a" "$T/err" || fail "stderr: $(cat "$T/err")"
  grep -q "lib/x.txt" "$T/err" || fail "stderr: $(cat "$T/err")"
  wait_done "$a" || return 1
  wait_done "$b" || return 1
}

test_submit_overlap_no_warn_disjoint() {
  write_ticket docs/t/02-b.md lib/x.txt
  write_ticket docs/t/03-c.md lib/z.txt
  commit_all overlap-tickets
  export FAKE_AGY_MODE=sleep FAKE_AGY_SLEEP=3
  sub submit docs/t/02-b.md
  assert_rc 0 || return 1
  local a b
  a="$(jget '.[0].id')"
  sub submit docs/t/03-c.md
  assert_rc 0 || return 1
  b="$(jget '.[0].id')"
  if grep -q "overlaps" "$T/err"; then fail "unexpected warning: $(cat "$T/err")"; fi
  wait_done "$a" || return 1
  wait_done "$b" || return 1
}

test_submit_overlap_no_warn_other_repo() {
  write_ticket docs/t/02-b.md lib/x.txt
  commit_all overlap-tickets
  local d="$SUBCON_STATE/jobs/20260101-000000-fake-active"
  mkdir -p "$d"
  echo running > "$d/state"
  write_ticket "$d/ticket.md" lib/x.txt
  printf '{"id":"20260101-000000-fake-active","repo":"/elsewhere"}' > "$d/meta.json"
  sub submit docs/t/02-b.md
  assert_rc 0 || return 1
  if grep -q "overlaps" "$T/err"; then fail "unexpected warning: $(cat "$T/err")"; fi
  local b
  b="$(jget '.[0].id')"
  wait_done "$b" || return 1
}

test_submit_overlap_warn_same_repo() {
  write_ticket docs/t/02-b.md lib/x.txt
  commit_all overlap-tickets
  local d="$SUBCON_STATE/jobs/20260101-000000-fake-active"
  mkdir -p "$d"
  echo running > "$d/state"
  write_ticket "$d/ticket.md" lib/x.txt
  printf '{"id":"20260101-000000-fake-active","repo":"%s"}' "$TOP" > "$d/meta.json"
  sub submit docs/t/02-b.md
  assert_rc 0 || return 1
  grep -q "overlaps with active job 20260101-000000-fake-active" "$T/err" || fail "stderr: $(cat "$T/err")"
  local b
  b="$(jget '.[0].id')"
  wait_done "$b" || return 1
}

test_submit_overlap_no_warn_finished() {
  write_ticket docs/t/02-b.md lib/x.txt
  write_ticket docs/t/03-c.md lib/x.txt
  commit_all overlap-tickets
  sub run docs/t/02-b.md
  assert_rc 0 || return 1
  sub submit docs/t/03-c.md
  assert_rc 0 || return 1
  if grep -q "overlaps" "$T/err"; then fail "unexpected warning: $(cat "$T/err")"; fi
  local b
  b="$(jget '.[0].id')"
  wait_done "$b" || return 1
}

test_submit_issue_shorthand() {
  git remote add origin git@github.com:Q0tzly/subcon.git
  submit_one --issue "#7" docs/t/01-a.md || return 1
  assert_eq "$(jq -c .issue "$(jobdir "$ID")/meta.json")" '{"repo":"Q0tzly/subcon","number":7}' meta.issue
  wait_done "$ID" || return 1
  assert_eq "$(result "$ID" -c .issue)" '{"repo":"Q0tzly/subcon","number":7}' result.issue
}

test_submit_issue_full() {
  submit_one --issue "Q0tzly/other#12" docs/t/01-a.md || return 1
  assert_eq "$(jq -c .issue "$(jobdir "$ID")/meta.json")" '{"repo":"Q0tzly/other","number":12}' meta.issue
}

test_submit_issue_url() {
  submit_one --issue "https://github.com/Q0tzly/subcon/issues/34" docs/t/01-a.md || return 1
  assert_eq "$(jq -c .issue "$(jobdir "$ID")/meta.json")" '{"repo":"Q0tzly/subcon","number":34}' meta.issue
}

test_submit_issue_invalid() {
  subx submit --issue banana docs/t/01-a.md
  assert_rc 1 || return 1
  subx submit --issue "#0" docs/t/01-a.md
  assert_rc 1 || return 1
  subx submit --issue "#abc" docs/t/01-a.md
  assert_rc 1 || return 1
  assert_eq "$(jobcount)" 0 jobs
}

test_submit_no_issue() {
  submit_one docs/t/01-a.md || return 1
  assert_eq "$(jq -r .issue "$(jobdir "$ID")/meta.json")" "null" meta.issue
  wait_done "$ID" || return 1
  assert_eq "$(result "$ID" .issue)" "null" result.issue
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

test_query_wait_timeout_units() {
  export FAKE_AGY_MODE=sleep FAKE_AGY_SLEEP=8
  submit_one docs/t/01-a.md || return 1
  sub wait --timeout 1s "$ID"
  assert_rc 5 || return 1
  assert_match "$(jget '.[0].state')" '^(queued|running)$' state
  sub wait --timeout 1m "$ID"
  assert_rc 0 || return 1
  assert_eq "$(jget '.[0].state')" finished state
}

test_query_wait_timeout_invalid() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub wait --timeout 5x "$ID"
  assert_rc 1 || return 1
  sub wait --timeout abc "$ID"
  assert_rc 1 || return 1
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

# ---- commit (23) ---------------------------------------------------------

REVIEWER='Test Reviewer <reviewer@example.invalid>'

test_commit_ok() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub apply "$ID"
  assert_rc 0 || return 1
  local before
  before="$(git rev-parse HEAD)"
  SUBCON_REVIEWER="$REVIEWER" sub commit -m "feat: fake change" "$ID"
  assert_rc 0 || return 1
  assert_eq "$(jget -r .id)" "$ID" stdout_id
  local hash
  hash="$(jget -r .commit)"
  assert_eq "$(git rev-parse HEAD)" "$hash" head_is_new_commit
  [[ "$hash" != "$before" ]] || fail "HEAD did not move"
  assert_eq "$(git log -1 --format=%s)" "feat: fake change" subject
  git log -1 --format=%B | grep -Fxq "Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>" \
    || fail "implementer trailer missing: $(git log -1 --format=%B)"
  git log -1 --format=%B | grep -Fxq "Reviewed-By: $REVIEWER" \
    || fail "reviewer trailer missing: $(git log -1 --format=%B)"
  assert_eq "$(git status --porcelain)" "" tree_clean
  grep -q '"event":"committed"' "$(hist)" || fail "no committed event in history"
}

test_commit_closes_same_repo() {
  git remote add origin git@github.com:Q0tzly/subcon.git
  submit_one --issue "#7" docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub apply "$ID"
  assert_rc 0 || return 1
  SUBCON_REVIEWER="$REVIEWER" sub commit -m "feat: fake change" "$ID"
  assert_rc 0 || return 1
  git log -1 --format=%B | grep -Fxq "Closes #7" \
    || fail "no Closes line: $(git log -1 --format=%B)"
}

test_commit_closes_cross_repo() {
  submit_one --issue "Q0tzly/other#12" docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub apply "$ID"
  assert_rc 0 || return 1
  SUBCON_REVIEWER="$REVIEWER" sub commit -m "feat: fake change" "$ID"
  assert_rc 0 || return 1
  git log -1 --format=%B | grep -Fxq "Closes Q0tzly/other#12" \
    || fail "no cross-repo Closes line: $(git log -1 --format=%B)"
}

test_commit_no_closes_without_issue() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub apply "$ID"
  assert_rc 0 || return 1
  SUBCON_REVIEWER="$REVIEWER" sub commit -m "feat: fake change" "$ID"
  assert_rc 0 || return 1
  ! git log -1 --format=%B | grep -q "Closes" \
    || fail "unexpected Closes line: $(git log -1 --format=%B)"
}

test_commit_closes_not_duplicated() {
  git remote add origin git@github.com:Q0tzly/subcon.git
  submit_one --issue "#7" docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub apply "$ID"
  assert_rc 0 || return 1
  SUBCON_REVIEWER="$REVIEWER" sub commit -m "feat: fake change

Closes #7" "$ID"
  assert_rc 0 || return 1
  assert_eq "$(git log -1 --format=%B | grep -c '^Closes #7$')" "1" closes-count
}

test_commit_edited() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub apply "$ID"
  assert_rc 0 || return 1
  SUBCON_REVIEWER="$REVIEWER" sub commit -m "feat: fake change" --edited "$ID"
  assert_rc 0 || return 1
  git log -1 --format=%B | grep -Fxq "Co-Authored-By: $REVIEWER" \
    || fail "reviewer co-author line missing: $(git log -1 --format=%B)"
  assert_eq "$(git log -1 --format=%B | grep -c '^Co-Authored-By:')" 2 coauthor_lines
}

test_commit_no_reviewer() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub apply "$ID"
  assert_rc 0 || return 1
  local before
  before="$(git rev-parse HEAD)"
  sub commit -m "feat: fake change" "$ID"
  assert_rc 1 || return 1
  grep -q "SUBCON_REVIEWER" "$T/err" || fail "stderr does not mention SUBCON_REVIEWER: $(cat "$T/err")"
  assert_eq "$(git rev-parse HEAD)" "$before" head_unchanged
}

test_commit_no_message() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub apply "$ID"
  assert_rc 0 || return 1
  local before
  before="$(git rev-parse HEAD)"
  SUBCON_REVIEWER="$REVIEWER" sub commit "$ID"
  assert_rc 1 || return 1
  assert_eq "$(git rev-parse HEAD)" "$before" head_unchanged
}

test_commit_not_applied() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  local before
  before="$(git rev-parse HEAD)"
  SUBCON_REVIEWER="$REVIEWER" sub commit -m "feat: fake change" "$ID"
  assert_rc 1 || return 1
  assert_eq "$(git rev-parse HEAD)" "$before" head_unchanged
  assert_eq "$(git status --porcelain)" "" tree_clean
}

test_commit_unrelated_untouched() {
  echo other > other.txt
  commit_all "add other"
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub apply "$ID"
  assert_rc 0 || return 1
  echo dirty >> other.txt
  echo stray > stray.txt
  SUBCON_REVIEWER="$REVIEWER" sub commit -m "feat: fake change" "$ID"
  assert_rc 0 || return 1
  assert_eq "$(git show HEAD:other.txt)" "other" unrelated_not_swept_in
  assert_match "$(git status --porcelain)" "other.txt" unrelated_change_remains
  assert_match "$(git status --porcelain)" "stray.txt" untracked_remains
}

test_commit_checks_failed() {
  export FAKE_AGY_MODE=outside
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub apply "$ID"
  assert_rc 0 || return 1
  local before
  before="$(git rev-parse HEAD)"
  SUBCON_REVIEWER="$REVIEWER" sub commit -m "feat: fake change" "$ID"
  assert_rc 1 || return 1
  assert_eq "$(git rev-parse HEAD)" "$before" head_unchanged
}

test_commit_no_changes() {
  export FAKE_AGY_MODE=partial
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub apply "$ID"
  assert_rc 0 || return 1
  local before
  before="$(git rev-parse HEAD)"
  SUBCON_REVIEWER="$REVIEWER" sub commit -m "feat: fake change" "$ID"
  assert_rc 1 || return 1
  assert_eq "$(git rev-parse HEAD)" "$before" head_unchanged
}

test_commit_unknown_id() {
  SUBCON_REVIEWER="$REVIEWER" sub commit -m "feat: fake change" nope
  assert_rc 1
}

test_commit_twice() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub apply "$ID"
  assert_rc 0 || return 1
  SUBCON_REVIEWER="$REVIEWER" sub commit -m "feat: fake change" "$ID"
  assert_rc 0 || return 1
  local before
  before="$(git rev-parse HEAD)"
  SUBCON_REVIEWER="$REVIEWER" sub commit -m "feat: again" "$ID"
  assert_rc 1 || return 1
  assert_eq "$(git rev-parse HEAD)" "$before" head_unchanged
}

# ---- checks (53) ---------------------------------------------------------

# FAKE_AGY_MODE=outside changes the ticket's first Files entry (README.md)
# and additionally creates outside.txt, so the stored checks come out
# ok:false with outside.txt outside the declared scope.
outside_job() {
  export FAKE_AGY_MODE=outside
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  assert_eq "$(result "$ID" .checks.ok)" false checks.ok
  assert_eq "$(result "$ID" -c .checks.outside_files)" '["outside.txt"]' outside
}

test_checks_recompute_after_ticket_fix() {
  outside_job || return 1
  write_ticket docs/t/01-a.md README.md outside.txt
  sub checks "$ID"
  assert_rc 0 || return 1
  assert_eq "$(jget .ok)" true new-ok
  assert_eq "$(result "$ID" .checks.ok)" true stored-ok
  assert_match "$(result "$ID" .checks.recomputed_at)" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' recomputed_at
  assert_eq "$(result "$ID" -c .checks.previous_checks.outside_files)" '["outside.txt"]' previous-outside
  sub apply "$ID"
  assert_rc 0 || return 1
  SUBCON_REVIEWER="$REVIEWER" sub commit -m "feat: fake change" "$ID"
  assert_rc 0 || return 1
}

test_checks_recompute_still_outside() {
  outside_job || return 1
  sub checks "$ID"
  assert_rc 0 || return 1
  assert_eq "$(jget .ok)" false still-ok
  assert_eq "$(result "$ID" -c .checks.previous_checks.outside_files)" '["outside.txt"]' previous-outside
}

test_checks_unknown() {
  sub checks no-such-job-id
  assert_rc 1 || return 1
}

test_checks_running() {
  export FAKE_AGY_MODE=sleep FAKE_AGY_SLEEP=6
  submit_one docs/t/01-a.md || return 1
  sub checks "$ID"
  assert_rc 1 || return 1
  wait_done "$ID" || return 1
}

# ---- reject (24) ---------------------------------------------------------

test_reject_ok() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  local old="$ID"
  sub reject -m "理由テキスト" "$old"
  assert_rc 0 || return 1
  assert_eq "$(jget -r .reject_of)" "$old" reject_of
  assert_eq "$(jget -r .ticket)" "docs/t/01-a.md" ticket
  local new
  new="$(jget -r .id)"
  [[ -n "$new" && "$new" != "null" && "$new" != "$old" ]] || fail "no new job id: $OUT"
  [[ -d "$(jobdir "$old")" ]] || fail "old job was discarded"
  grep -q "理由テキスト" docs/t/01-a.md || fail "reason not in ticket: $(cat docs/t/01-a.md)"
  grep -q "^## Notes" docs/t/01-a.md || fail "no Notes section added: $(cat docs/t/01-a.md)"
  assert_eq "$(git log -1 --format=%s)" "reject: docs/t/01-a.md" commit_subject
  assert_eq "$(git status --porcelain)" "" tree_clean
  grep -q '"event":"rejected"' "$(hist)" || fail "no rejected event in history"
  wait_done "$new" || return 1
  assert_eq "$(result "$new" .state)" finished new_job_state
}

test_reject_existing_notes() {
  mkdir -p docs/t2
  cat > docs/t2/01-b.md <<'EOF'
# t

## Goal
g

## Files
- README.md

## Notes
- 既存のメモ

## Acceptance
- `true`
EOF
  commit_all "add t2"
  sub submit docs/t2/01-b.md
  assert_rc 0 || return 1
  ID="$(jget -r '.[0].id')"
  wait_done "$ID" || return 1
  sub reject -m "直してほしい" "$ID"
  assert_rc 0 || return 1
  awk '/^## Notes/{n=1} /^## Acceptance/{n=0} n' docs/t2/01-b.md | grep -q "直してほしい" \
    || fail "reason not inside Notes section: $(cat docs/t2/01-b.md)"
  grep -q "既存のメモ" docs/t2/01-b.md || fail "existing note lost"
}

test_reject_no_message() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  local before
  before="$(git rev-parse HEAD)"
  sub reject "$ID"
  assert_rc 1 || return 1
  assert_eq "$(git rev-parse HEAD)" "$before" head_unchanged
  assert_eq "$(git status --porcelain)" "" tree_clean
}

test_reject_unknown_id() {
  sub reject -m "x" nope
  assert_rc 1
}

test_reject_unfinished() {
  export FAKE_AGY_MODE=sleep FAKE_AGY_SLEEP=30
  submit_one docs/t/01-a.md || return 1
  wait_state "$ID" running || return 1
  sub reject -m "x" "$ID"
  assert_rc 1 || return 1
  assert_eq "$(git status --porcelain)" "" tree_clean
}

test_reject_dirty_ticket() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  echo dirty >> docs/t/01-a.md
  local before
  before="$(git rev-parse HEAD)"
  sub reject -m "理由" "$ID"
  assert_rc 1 || return 1
  assert_eq "$(git rev-parse HEAD)" "$before" head_unchanged
  ! grep -q "理由" docs/t/01-a.md || fail "reason appended despite dirty ticket"
}

test_reject_cap() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub reject -m "1回目" "$ID"
  assert_rc 0 || return 1
  local j2
  j2="$(jget -r .id)"
  wait_done "$j2" || return 1
  sub reject -m "2回目" "$j2"
  assert_rc 0 || return 1
  local j3
  j3="$(jget -r .id)"
  wait_done "$j3" || return 1
  sub reject -m "3回目" "$j3"
  assert_rc 1 || return 1
  assert_eq "$(jobcount)" 3 jobs
}

test_reject_preserves_runner_model() {
  submit_one --model gemini-3.8-flash-high docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub reject -m "理由" "$ID"
  assert_rc 0 || return 1
  local new
  new="$(jget -r .id)"
  assert_eq "$(jq -r .model "$(jobdir "$new")/meta.json")" "gemini-3.8-flash-high" model_preserved
  assert_eq "$(jq -r .runner "$(jobdir "$new")/meta.json")" "local" runner_preserved
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
  assert_eq "$(jq -c .tokens <<<"$l")" '{"input":100,"output":20,"total":120,"cache_read":30,"thinking":10}' tokens
  assert_eq "$(jq -r .resume_of <<<"$l")" null resume_of
}

test_history_driver_field() {
  sub run docs/t/01-a.md
  assert_rc 0 || return 1
  assert_eq "$(jq -r .driver <<<"$(hline 1)")" agy driver.default
  local fc
  fc="$(fake_claude_path)"
  PATH="$fc:$PATH" sub run --driver claude docs/t/01-a.md
  assert_rc 0 || return 1
  assert_eq "$(jq -r .driver <<<"$(hline 2)")" claude driver.claude
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

test_history_cost_recorded() {
  local fc
  fc="$(fake_claude_path)"
  PATH="$fc:$PATH" sub run --driver claude docs/t/01-a.md
  assert_rc 0 || return 1
  local l
  l="$(hline 1)"
  assert_eq "$(jq -r .cost_usd <<<"$l")" "0.01" cost_usd
}

test_history_cost_absent_null() {
  sub run docs/t/01-a.md
  assert_rc 0 || return 1
  local l
  l="$(hline 1)"
  assert_eq "$(jq -r .cost_usd <<<"$l")" "null" cost_usd
}

test_history_repo_slug() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  assert_eq "$(jq -r --arg id "$ID" 'select(.type == "job" and .id == $id) | .repo_slug' "$(hist)")" "null" slug-without-origin
  git remote add origin git@github.com:Q0tzly/subcon.git
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  assert_eq "$(jq -r --arg id "$ID" 'select(.type == "job" and .id == $id) | .repo_slug' "$(hist)")" "Q0tzly/subcon" slug-with-origin
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
  local created epoch
  epoch=$(( $(date +%s) - ${10:-0} * 86400 ))
  # BSD date formats an epoch with -r, GNU date with -d @<epoch>.
  if date -d @0 +%s >/dev/null 2>&1; then
    created="$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ)"
  else
    created="$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ)"
  fi
  jq -cn --arg id "$1" --arg repo "$2" --arg model "$3" --arg state "$4" --arg created "$created" \
    --argjson status "$( [[ $5 == null ]] && echo null || echo "\"$5\"")" \
    --argjson ok "$6" --argjson dur "$7" --argjson tin "$8" --argjson tout "$9" --arg drv "${11:-}" \
    --arg cst "${12:-}" '
    {type: "job", id: $id, repo: $repo, ticket: "docs/t/x.md", model: $model, runner: "local",
     created_at: $created, finished_at: $created, duration_s: $dur, state: $state, status: $status,
     checks_ok: $ok, files_changed: 1, insertions: 1, deletions: 0,
     tokens: (if $tin == null then null else {input: $tin, output: $tout, total: ($tin + $tout), cache_read: 5, thinking: 2} end),
     resume_of: null} + (if $drv == "" then {} else {driver: $drv} end)
     + (if $cst == "" then {} else {cost_usd: ($cst | tonumber)} end)' >> "$(hist)"
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
  assert_eq "$(jget -c .tokens)" '{"input":128,"output":32,"total":160,"cache_read":15,"thinking":6}' tokens
  assert_eq "$(jget -c .by_model.m1)" '{"jobs":2,"success":1,"applied":1,"tokens_total":150}' m1
  assert_eq "$(jget -c .by_model.m2)" '{"jobs":2,"success":0,"applied":1,"tokens_total":10}' m2
}

test_stats_cost() {
  mkdir -p "$SUBCON_STATE"
  hjob A "$TOP" m1 finished done true 10 80 20 0 "" 0.5
  hjob B "$TOP" m1 finished done true 10 80 20 0 "" 0.25
  hjob C "$TOP" m1 finished done true 10 80 20
  sub stats
  assert_rc 0 || return 1
  assert_eq "$(jget .cost.usd)" "0.75" cost.usd
  assert_eq "$(jget .cost.priced_jobs)" "2" priced_jobs
  assert_eq "$(jget .cost.unpriced_jobs)" "1" unpriced_jobs
  sub stats --text
  assert_rc 0 || return 1
  grep -q "Cost:" <<<"$OUT" || fail "text output lacks the Cost line: $OUT"
  grep -q "0.75" <<<"$OUT" || fail "text output lacks the cost total: $OUT"
}

test_stats_by_driver() {
  mkdir -p "$SUBCON_STATE"
  hjob A "$TOP" m1 finished done true 10 10 5 0 claude
  hjob B "$TOP" m1 finished partial true 10 10 5 0 claude
  hjob C "$TOP" m1 finished done true 10 10 5 0 agy
  hjob D "$TOP" m1 finished done true 10 10 5
  sub stats
  assert_rc 0 || return 1
  assert_eq "$(jget -c .by_driver.claude)" '{"jobs":2,"success":1,"applied":0,"tokens_total":30}' by_driver.claude
  assert_eq "$(jget -c .by_driver.agy)" '{"jobs":2,"success":2,"applied":0,"tokens_total":30}' by_driver.agy
  sub stats --text
  assert_rc 0 || return 1
  grep -q "Driver breakdown:" <<<"$OUT" || fail "text output lacks the driver breakdown: $OUT"
  grep -q "claude" <<<"$OUT" || fail "text output lacks the claude row: $OUT"
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
  grep -q 'cache_read 15, thinking 6' <<<"$OUT" || fail "no cache_read/thinking in Tokens line"
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
  assert_eq "$(jget .tokens.cache_read)" 60 tokens.cache_read
  assert_eq "$(jget .tokens.thinking)" 20 tokens.thinking
}

# ---- export (49) ---------------------------------------------------------

test_export_basic() {
  mkdir -p "$SUBCON_STATE"
  hjob A "$TOP" m1 finished done true 10 80 20
  hjob B "/other/repo" m1 finished done true 10 80 20
  printf '{"type":"event","id":"A","event":"applied","at":"2026-01-01T00:00:01Z"}\n' >> "$(hist)"
  sub export
  assert_rc 0 || return 1
  assert_eq "$(wc -l <<<"$OUT" | tr -d ' ')" "2" line-count
  local env1
  env1="$(head -1 <<<"$OUT")"
  assert_eq "$(jq -r .type <<<"$env1")" "export" envelope-type
  assert_eq "$(jq -r .v <<<"$env1")" "1" envelope-v
  assert_eq "$(jq -r .scope <<<"$env1")" "repo" envelope-scope
  assert_eq "$(jq -r .repo <<<"$env1")" "$TOP" envelope-repo
  assert_match "$(jq -r .exported_at <<<"$env1")" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' exported_at
  assert_eq "$(tail -1 <<<"$OUT" | jq -r .id)" "A" job-line
  ! grep -q '"type":"event"' <<<"$OUT" || fail "event line leaked into export"
}

test_export_all() {
  mkdir -p "$SUBCON_STATE"
  hjob A "$TOP" m1 finished done true 10 80 20
  hjob B "/other/repo" m1 finished done true 10 80 20
  sub export --all
  assert_rc 0 || return 1
  assert_eq "$(wc -l <<<"$OUT" | tr -d ' ')" "3" line-count
  local env1
  env1="$(head -1 <<<"$OUT")"
  assert_eq "$(jq -r .scope <<<"$env1")" "all" envelope-scope
  assert_eq "$(jq -r .repo <<<"$env1")" "null" envelope-repo
}

test_export_since() {
  mkdir -p "$SUBCON_STATE"
  hjob OLD "$TOP" m1 finished done true 10 80 20 3
  hjob NEW "$TOP" m1 finished done true 10 80 20 0
  sub export --since 1d
  assert_rc 0 || return 1
  assert_eq "$(wc -l <<<"$OUT" | tr -d ' ')" "2" line-count
  assert_eq "$(tail -1 <<<"$OUT" | jq -r .id)" "NEW" job-line
}

test_export_empty() {
  sub export
  assert_rc 0 || return 1
  assert_eq "$(wc -l <<<"$OUT" | tr -d ' ')" "1" line-count
  assert_eq "$(jq -r .type <<<"$OUT")" "export" envelope-type
}

test_export_bad_args() {
  subx export --bogus
  assert_rc 1 || return 1
  subx export --since 3w
  assert_rc 1 || return 1
}

test_export_source() {
  sub export
  assert_rc 0 || return 1
  local s1 s2
  s1="$(head -1 <<<"$OUT" | jq -r .source)"
  assert_match "$s1" '^[0-9a-f]{32}$' source-format
  assert_eq "$(cat "$SUBCON_STATE/source")" "$s1" source-file
  sub export
  assert_rc 0 || return 1
  s2="$(head -1 <<<"$OUT" | jq -r .source)"
  assert_eq "$s2" "$s1" source-stable
}

test_export_source_regenerated() {
  sub export
  assert_rc 0 || return 1
  local s1 s2
  s1="$(head -1 <<<"$OUT" | jq -r .source)"
  rm -f "$SUBCON_STATE/source"
  sub export
  assert_rc 0 || return 1
  s2="$(head -1 <<<"$OUT" | jq -r .source)"
  assert_match "$s2" '^[0-9a-f]{32}$' source-format
  [[ "$s2" != "$s1" ]] || fail "source was not regenerated"
}

# ---- resume (08) ---------------------------------------------------------

# failed_job: a job that died mid-work with a conversation id.
failed_job() {
  FAKE_AGY_MODE=error submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
}

test_resume_issue_inherited() {
  git remote add origin git@github.com:Q0tzly/subcon.git
  FAKE_AGY_MODE=error submit_one --issue "#9" docs/t/01-a.md || return 1
  local old="$ID" new
  wait_done "$old" || return 1
  sub resume "$old"
  assert_rc 0 || return 1
  new="$(jget '.[0].id')"
  wait_done "$new" || return 1
  assert_eq "$(jq -c .issue "$(jobdir "$new")/meta.json")" '{"repo":"Q0tzly/subcon","number":9}' meta.issue
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

# ---- driver (39) -----------------------------------------------------------

# Copy the subcon tree to $SX with an extra fake driver installed, so
# driver-selection tests never touch the real tree.
make_driver_tree() {
  SX="$T/subcon-x"
  mkdir -p "$SX"
  cp -r "$ROOT/bin" "$ROOT/lib" "$ROOT/drivers" "$ROOT/runners" "$ROOT/schema" "$SX/"
  cat > "$SX/drivers/fakeok" <<'DRIVER_EOF'
#!/bin/bash
set -euo pipefail
case "${1:-}" in
  preflight) exit 0 ;;
  models) printf 'fake-1\tFake Model One\n'; exit 0 ;;
  default-model) echo fake-1; exit 0 ;;
esac
job_dir="$1"
prompt="$(cat "$SUBCON_PROMPT_FILE")"
if [[ -n "${SUBCON_CONVERSATION:-}" ]]; then
  f="$(git status --porcelain | awk 'NR == 1 { print $2 }')"
else
  f="$(awk '/^## /{ f = ($0 ~ /^## Files/); next } f && /^[-*][[:space:]]/ { sub(/^[-*][[:space:]]+/, ""); gsub(/`/, ""); print; exit }' <<<"$prompt")"
fi
echo "fake change" >> "$f"
if [[ "${FAKE_DRIVER_MODE:-ok}" == "error" ]]; then
  jq -cn '{status: "ERROR", conversation_id: "fake-conv-1", error: "fake driver error"}' > "$job_dir/agy.json"
  exit 1
fi
jq -cn --arg f "$f" '{status: "SUCCESS", conversation_id: "fake-conv-1", duration_seconds: 1, usage: {input_tokens: 1, output_tokens: 2, total_tokens: 3, cache_read_tokens: 0, thinking_tokens: 0}, structured_output: {status: "done", summary: "fake driver did it", files_changed: [$f], commands_run: [], design_questions: [], issues_found: []}}' > "$job_dir/agy.json"
DRIVER_EOF
  chmod +x "$SX/drivers/fakeok"
}

subx() { OUT="$("$SX/bin/subcon" "$@" 2>"$T/err")" && RC=0 || RC=$?; }

test_driver_agy_read_scope() {
  export FAKE_AGY_LOG="$T/agy.log"
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  local parent
  parent="$(dirname "$TOP")"
  grep -F "read_file($parent)" "$T/agy.log" >/dev/null || fail "settings missing read_file for repo parent"
  grep -F "read_file($(jobdir "$ID"))" "$T/agy.log" >/dev/null || fail "settings missing read_file for job dir"
}

test_driver_unknown() {
  sub submit --driver nope docs/t/01-a.md
  assert_rc 1 || return 1
  grep -q "unknown driver: nope" "$T/err" || fail "stderr: $(cat "$T/err")"
  assert_eq "$(jobcount)" 0 jobs
}

test_driver_agy_missing() {
  local cp h
  cp="$(clean_path)"
  h="$(preflight_home no-agy)"
  HOME="$h" PATH="$cp" sub submit --driver agy docs/t/01-a.md
  assert_rc 1 || return 1
  grep -q "agy not found" "$T/err" || fail "stderr: $(cat "$T/err")"
  assert_eq "$(jobcount)" 0 jobs
}

test_driver_fake_ok() {
  make_driver_tree
  subx submit --driver fakeok docs/t/01-a.md
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
  wait_done "$ID" || return 1
  local d
  d="$(jobdir "$ID")"
  assert_eq "$(jq -r .driver "$d/meta.json")" fakeok meta.driver
  assert_eq "$(jq -r .model "$d/meta.json")" fake-1 meta.model
  assert_eq "$(result "$ID" .status)" done status
  assert_eq "$(result "$ID" .checks.ok)" true checks.ok
  assert_eq "$(result "$ID" .report.summary)" "fake driver did it" report.summary
}

test_driver_fake_trailer() {
  make_driver_tree
  SUBCON_DRIVER=fakeok subx trailer
  assert_rc 0 || return 1
  assert_match "$OUT" '^Co-Authored-By: Fake Model One <[^>]+>$' trailer
}

test_driver_trailer_latest_job() {
  make_driver_tree
  subx run --driver fakeok docs/t/01-a.md
  assert_rc 0 || return 1
  subx trailer
  assert_rc 0 || return 1
  assert_match "$OUT" 'Fake Model One' trailer
  # Job IDs sort by second-resolution timestamp, so cross a second boundary
  # before creating the next job (otherwise "latest" is ambiguous).
  sleep 2
  sub run docs/t/01-a.md
  assert_rc 0 || return 1
  subx trailer
  assert_rc 0 || return 1
  assert_match "$OUT" 'Gemini 3\.8 Flash' trailer
  local fc
  fc="$(fake_claude_path)"
  SUBCON_DRIVER=claude PATH="$fc:$PATH" subx trailer
  assert_rc 0 || return 1
  assert_match "$OUT" 'Claude Haiku 5\.5' trailer
}

test_driver_trailer_latest_job_other_repo() {
  make_driver_tree
  local d="$SUBCON_STATE/jobs/20990101-000000-zz-otherrepo"
  mkdir -p "$d"
  cat > "$d/meta.json" <<'JSON'
{"id":"20990101-000000-zz-otherrepo","repo":"/elsewhere","ticket":"docs/t/x.md","model":"claude-haiku-5-5","runner":"local","driver":"claude"}
JSON
  subx trailer
  assert_rc 0 || return 1
  assert_match "$OUT" 'Gemini 3\.8 Flash' trailer
}

test_driver_trailer_latest_job_same_second() {
  make_driver_tree
  local d1="$SUBCON_STATE/jobs/20261112-120000-01-a-rand1"
  local d2="$SUBCON_STATE/jobs/20261112-120000-01-a-rand2"
  mkdir -p "$d1" "$d2"

  # rand2 has lexicographically larger job ID, but rand1 has newer created_at.
  cat > "$d1/meta.json" <<JSON
{"id":"20261112-120000-01-a-rand1","repo":"$TOP","ticket":"docs/t/01-a.md","driver":"fakeok","model":"fake-1","created_at":"2026-11-12T12:00:05Z"}
JSON
  cat > "$d2/meta.json" <<JSON
{"id":"20261112-120000-01-a-rand2","repo":"$TOP","ticket":"docs/t/01-a.md","driver":"agy","model":"gemini-3.8-flash-medium","created_at":"2026-11-12T12:00:01Z"}
JSON

  subx trailer
  assert_rc 0 || return 1
  assert_match "$OUT" 'Fake Model One' trailer

  local meta
  meta="$(export SUBCON_ROOT="$ROOT"; source "$ROOT/lib/common.sh"; latest_job_meta)"
  assert_eq "$meta" "$d1/meta.json" "newer created_at wins" || return 1

  # Tiebreak 1: same created_at, newer mtime wins.
  cat > "$d1/meta.json" <<JSON
{"id":"20261112-120000-01-a-rand1","repo":"$TOP","ticket":"docs/t/01-a.md","driver":"fakeok","model":"fake-1","created_at":"2026-11-12T12:00:00Z"}
JSON
  cat > "$d2/meta.json" <<JSON
{"id":"20261112-120000-01-a-rand2","repo":"$TOP","ticket":"docs/t/01-a.md","driver":"agy","model":"gemini-3.8-flash-medium","created_at":"2026-11-12T12:00:00Z"}
JSON
  touch -t 202601011200.00 "$d2/meta.json"
  touch -t 202601011200.10 "$d1/meta.json"
  subx trailer
  assert_rc 0 || return 1
  assert_match "$OUT" 'Fake Model One' trailer

  meta="$(export SUBCON_ROOT="$ROOT"; source "$ROOT/lib/common.sh"; latest_job_meta)"
  assert_eq "$meta" "$d1/meta.json" "newer mtime wins on equal created_at" || return 1

  # Tiebreak 2: same created_at and same mtime, larger job ID wins (rand2 > rand1).
  touch -t 202601011200.00 "$d1/meta.json"
  touch -t 202601011200.00 "$d2/meta.json"
  subx trailer
  assert_rc 0 || return 1
  assert_match "$OUT" 'Gemini 3\.8 Flash' trailer

  meta="$(export SUBCON_ROOT="$ROOT"; source "$ROOT/lib/common.sh"; latest_job_meta)"
  assert_eq "$meta" "$d2/meta.json" "larger ID wins on equal created_at and mtime" || return 1
}

test_driver_fake_resume_pinned() {
  make_driver_tree
  export FAKE_DRIVER_MODE=error
  subx submit --driver fakeok docs/t/01-a.md
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
  wait_done "$ID" || return 1
  export FAKE_DRIVER_MODE=ok
  subx resume "$ID"
  assert_rc 0 || return 1
  local new
  new="$(jget '.[0].id')"
  wait_done "$new" || return 1
  assert_eq "$(jq -r .driver "$(jobdir "$new")/meta.json")" fakeok resumed.meta.driver
  assert_eq "$(result "$new" .status)" done resumed.status
}

test_driver_container_guard() {
  make_driver_tree
  subx submit --runner container --driver fakeok docs/t/01-a.md
  assert_rc 1 || return 1
  grep -q "supports the agy and claude drivers only" "$T/err" || fail "stderr: $(cat "$T/err")"
  assert_eq "$(jobcount)" 0 jobs
}

test_driver_ci_guard() {
  make_driver_tree
  subx submit --runner ci --driver fakeok docs/t/01-a.md
  assert_rc 1 || return 1
  grep -q "the ci runner supports the agy and claude drivers only" "$T/err" || fail "stderr: $(cat "$T/err")"
  assert_eq "$(jobcount)" 0 jobs
}

fake_claude_path() {
  local bin="$T/fcbin"
  mkdir -p "$bin"
  ln -s "$ROOT/tests/fake-claude" "$bin/claude"
  echo "$bin"
}

opencode_path() {
  local bin="$T/ocbin"
  mkdir -p "$bin"
  ln -s "$ROOT/tests/fake-opencode" "$bin/opencode"
  echo "$bin"
}

test_driver_claude_fake_ok() {
  make_driver_tree
  local fc
  fc="$(fake_claude_path)"
  PATH="$fc:$PATH" subx submit --driver claude docs/t/01-a.md
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
  wait_done "$ID" || return 1
  local d
  d="$(jobdir "$ID")"
  assert_eq "$(jq -r .driver "$d/meta.json")" claude meta.driver
  assert_eq "$(jq -r .model "$d/meta.json")" claude-haiku-5-5 meta.model
  assert_eq "$(result "$ID" .status)" done status
  assert_eq "$(result "$ID" .report.summary)" "fake claude did it" report.summary
  assert_eq "$(jq -r .usage.cache_read_tokens "$d/agy.json")" 30 agy.usage.cache_read
  assert_eq "$(jq -r .usage.total_tokens "$d/agy.json")" 30 agy.usage.total
  assert_eq "$(jq -r .cost_usd "$d/agy.json")" 0.01 agy.cost_usd
  local conv
  conv="$(jq -r .conversation_id "$d/agy.json")"
  [[ -n "$conv" && "$conv" != null ]] || fail "agy.json has no conversation_id"
  assert_eq "$(head -n 1 "$d/agy.stream" | jq -r .event)" init stream.first.event
  assert_eq "$(head -n 1 "$d/agy.stream" | jq -r .conversation_id)" "$conv" stream.init.conversation
}

test_driver_claude_resume() {
  make_driver_tree
  local fc
  fc="$(fake_claude_path)"
  export FAKE_CLAUDE_MODE=error
  PATH="$fc:$PATH" subx submit --driver claude docs/t/01-a.md
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
  wait_done "$ID" || return 1
  local conv
  conv="$(result "$ID" .conversation)"
  [[ -n "$conv" && "$conv" != null ]] || fail "failed job recorded no conversation"
  export FAKE_CLAUDE_MODE=ok
  PATH="$fc:$PATH" subx resume "$ID"
  assert_rc 0 || return 1
  local new
  new="$(jget '.[0].id')"
  wait_done "$new" || return 1
  assert_eq "$(jq -r .driver "$(jobdir "$new")/meta.json")" claude resumed.meta.driver
  assert_eq "$(result "$new" .status)" done resumed.status
  assert_eq "$(result "$new" .conversation)" "$conv" resumed.conversation
}

test_driver_claude_nojson() {
  make_driver_tree
  local fc
  fc="$(fake_claude_path)"
  export FAKE_CLAUDE_MODE=nojson
  PATH="$fc:$PATH" subx submit --driver claude docs/t/01-a.md
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
  wait_done "$ID" || return 1
  local d
  d="$(jobdir "$ID")"
  assert_eq "$(jq -r .status "$d/agy.json")" ERROR agy.status
  local conv
  conv="$(head -n 1 "$d/agy.stream" | jq -r .conversation_id)"
  [[ -n "$conv" && "$conv" != null ]] || fail "stream init has no conversation_id"
  assert_eq "$(jq -r .conversation_id "$d/agy.json")" "$conv" agy.conversation
  assert_eq "$(result "$ID" .conversation)" "$conv" result.conversation
}

test_driver_claude_preflight_missing() {
  make_driver_tree
  local cp h
  cp="$(clean_path)"
  h="$(preflight_home no-agy)"
  HOME="$h" PATH="$cp" subx submit --driver claude docs/t/01-a.md
  assert_rc 1 || return 1
  grep -q "claude not found" "$T/err" || fail "stderr: $(cat "$T/err")"
  assert_eq "$(jobcount)" 0 jobs
}

test_driver_claude_preflight_homebin() {
  make_driver_tree
  local cp h
  cp="$(clean_path)"
  h="$(preflight_home with-claude)"
  HOME="$h" PATH="$cp" subx submit --driver claude docs/t/01-a.md
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
  wait_done "$ID" || return 1
  assert_eq "$(result "$ID" .status)" done status
  assert_eq "$(result "$ID" .checks.ok)" true checks.ok
}

test_driver_opencode_ok() {
  make_driver_tree
  local oc
  oc="$(opencode_path)"
  PATH="$oc:$PATH" subx submit --driver opencode docs/t/01-a.md
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
  wait_done "$ID" || return 1
  local d
  d="$(jobdir "$ID")"
  assert_eq "$(jq -r .driver "$d/meta.json")" opencode meta.driver
  assert_eq "$(jq -r .model "$d/meta.json")" sakura/preview/Kimi-K2.7-Code meta.model
  assert_eq "$(result "$ID" .status)" done status
  assert_eq "$(result "$ID" .report.summary)" "fake opencode did it" report.summary
  assert_eq "$(result "$ID" .conversation)" ses-fake-1 conversation
  assert_eq "$(jq -r .usage.input_tokens "$d/agy.json")" 100 usage.input
  assert_eq "$(jq -r .usage.output_tokens "$d/agy.json")" 20 usage.output
  assert_eq "$(jq -r .usage.total_tokens "$d/agy.json")" 132 usage.total
  assert_eq "$(jq -r .usage.thinking_tokens "$d/agy.json")" 5 usage.thinking
  assert_eq "$(jq -r .usage.cache_read_tokens "$d/agy.json")" 7 usage.cache_read
  assert_eq "$(jq -r 'has("cost_usd")' "$d/agy.json")" false agy.cost_absent
  [[ -s "$d/prompt.driver.txt" ]] || fail "augmented prompt not written"
  grep -q "status" "$d/prompt.driver.txt" || fail "augmented prompt lacks the schema"
}

test_driver_opencode_fenced() {
  make_driver_tree
  local oc
  oc="$(opencode_path)"
  export FAKE_OPENCODE_MODE=fenced
  PATH="$oc:$PATH" subx submit --driver opencode docs/t/01-a.md
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
  wait_done "$ID" || return 1
  assert_eq "$(result "$ID" .status)" done status
  assert_eq "$(result "$ID" .report.summary)" "fake opencode did it" report.summary
}

test_driver_opencode_prose() {
  make_driver_tree
  local oc
  oc="$(opencode_path)"
  export FAKE_OPENCODE_MODE=prose
  PATH="$oc:$PATH" subx submit --driver opencode docs/t/01-a.md
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
  wait_done "$ID" || return 1
  assert_eq "$(result "$ID" .status)" done status
  assert_eq "$(result "$ID" .report.summary)" "fake opencode did it" report.summary
}

test_driver_opencode_noreport() {
  make_driver_tree
  local oc
  oc="$(opencode_path)"
  export FAKE_OPENCODE_MODE=noreport
  PATH="$oc:$PATH" subx run --driver opencode docs/t/01-a.md
  assert_rc 2 || return 1
  assert_eq "$(jget .state)" finished state
  assert_eq "$(jget .status)" null status
  assert_eq "$(jget .report)" null report
  local d
  d="$(jobdir "$(jget .id)")"
  assert_eq "$(jq -r 'has("structured_output")' "$d/agy.json")" false agy.structured_absent
}

test_driver_opencode_badstatus() {
  make_driver_tree
  local oc
  oc="$(opencode_path)"
  export FAKE_OPENCODE_MODE=badstatus
  PATH="$oc:$PATH" subx submit --driver opencode docs/t/01-a.md
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
  wait_done "$ID" || return 1
  assert_eq "$(result "$ID" .state)" finished state
  assert_eq "$(result "$ID" .status)" null status
}

test_driver_opencode_error() {
  make_driver_tree
  local oc
  oc="$(opencode_path)"
  export FAKE_OPENCODE_MODE=error
  PATH="$oc:$PATH" subx submit --driver opencode docs/t/01-a.md
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
  wait_done "$ID" || return 1
  assert_eq "$(result "$ID" .state)" failed state
  assert_eq "$(result "$ID" .conversation)" ses-fake-1 conversation
}

test_driver_opencode_watchdog() {
  make_driver_tree
  local oc
  oc="$(opencode_path)"
  export FAKE_OPENCODE_MODE=stall FAKE_OPENCODE_MARKER="$T/oc-marker"
  PATH="$oc:$PATH" SUBCON_OPENCODE_WATCHDOG=2 subx submit --driver opencode docs/t/01-a.md
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
  wait_done "$ID" || return 1
  assert_eq "$(result "$ID" .state)" finished state
  assert_eq "$(result "$ID" .status)" done status
}

test_driver_opencode_resume() {
  make_driver_tree
  local oc
  oc="$(opencode_path)"
  export FAKE_OPENCODE_MODE=error
  PATH="$oc:$PATH" subx submit --driver opencode docs/t/01-a.md
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
  wait_done "$ID" || return 1
  export FAKE_OPENCODE_MODE=ok
  PATH="$oc:$PATH" subx resume "$ID"
  assert_rc 0 || return 1
  local new
  new="$(jget '.[0].id')"
  wait_done "$new" || return 1
  assert_eq "$(result "$new" .status)" done resumed.status
  assert_eq "$(result "$new" .conversation)" ses-fake-1 resumed.conversation
}

test_driver_opencode_preflight_missing() {
  make_driver_tree
  local cp h
  cp="$(clean_path)"
  h="$(preflight_home no-agy)"
  HOME="$h" PATH="$cp" subx submit --driver opencode docs/t/01-a.md
  assert_rc 1 || return 1
  grep -q "opencode not found" "$T/err" || fail "stderr: $(cat "$T/err")"
  assert_eq "$(jobcount)" 0 jobs
}

test_driver_opencode_preflight_homebin() {
  make_driver_tree
  local cp h
  cp="$(clean_path)"
  h="$(preflight_home with-opencode)"
  HOME="$h" PATH="$cp" subx submit --driver opencode docs/t/01-a.md
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
  wait_done "$ID" || return 1
  assert_eq "$(result "$ID" .status)" done status
  assert_eq "$(result "$ID" .checks.ok)" true checks.ok
}

test_driver_opencode_custom_model_trailer() {
  make_driver_tree
  local oc
  oc="$(opencode_path)"
  PATH="$oc:$PATH" subx submit --driver opencode --model sakura/custom-model-x docs/t/01-a.md
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
  wait_done "$ID" || return 1
  PATH="$oc:$PATH" subx trailer --driver opencode --model sakura/custom-model-x
  assert_rc 0 || return 1
  assert_match "$OUT" '^Co-Authored-By: sakura/custom-model-x <[^>]+>$' trailer
}

# ---- preflight (15) --------------------------------------------------------

test_preflight_missing_submit() {
  local cp h
  cp="$(clean_path)"
  h="$(preflight_home no-agy)"
  HOME="$h" PATH="$cp" sub submit docs/t/01-a.md
  assert_rc 1 || return 1
  grep -q "agy" "$T/err" || fail "stderr does not mention agy: $(cat "$T/err")"
  assert_eq "$(jobcount)" 0 jobs
}

test_preflight_missing_trailer() {
  local cp h
  cp="$(clean_path)"
  h="$(preflight_home no-agy)"
  HOME="$h" PATH="$cp" sub trailer
  assert_rc 1 || return 1
  grep -q "agy not found" "$T/err" || fail "stderr: $(cat "$T/err")"
}

test_preflight_missing_guide_ok() {
  local cp h
  cp="$(clean_path)"
  h="$(preflight_home no-agy)"
  HOME="$h" PATH="$cp" sub guide
  assert_rc 0 || return 1
  [[ -n "$OUT" ]] || fail "guide printed nothing"
}

test_preflight_fallback_run() {
  local cp h
  cp="$(clean_path)"
  h="$(preflight_home with-agy)"
  HOME="$h" PATH="$cp" sub run docs/t/01-a.md
  assert_rc 0 || return 1
  assert_eq "$(jget .state)" finished state
  assert_eq "$(jget .status)" done status
  HOME="$h" PATH="$cp" sub trailer
  assert_rc 0 || return 1
  assert_match "$OUT" 'Gemini 3\.8 Flash' trailer
}

test_preflight_claude_fallback_run() {
  make_driver_tree
  local cp h
  cp="$(clean_path)"
  h="$(preflight_home with-claude)"
  HOME="$h" PATH="$cp" subx run --driver claude docs/t/01-a.md
  assert_rc 0 || return 1
  assert_eq "$(jget .state)" finished state
  assert_eq "$(jget .status)" done status
  HOME="$h" PATH="$cp" subx trailer --driver claude
  assert_rc 0 || return 1
  assert_match "$OUT" 'Claude Haiku 5\.5' trailer
}

# ---- authwarn (15) ---------------------------------------------------------

test_authwarn_consumer_submit() {
  local h
  h="$(auth_home consumer)"
  HOME="$h" sub submit docs/t/01-a.md
  assert_rc 0 || return 1
  grep -q "consumer" "$T/err" || fail "no consumer warning: $(cat "$T/err")"
  grep -q "API key" "$T/err" || fail "warning does not mention API key: $(cat "$T/err")"
  assert_eq "$(jobcount)" 1 jobs
}

test_authwarn_api_key_run() {
  local h
  h="$(auth_home api-key)"
  HOME="$h" sub run docs/t/01-a.md
  assert_rc 0 || return 1
  assert_eq "$(jget .state)" finished state
  ! grep -q "consumer" "$T/err" || fail "warned in api-key mode: $(cat "$T/err")"
}

test_authwarn_silenced() {
  local h
  h="$(auth_home consumer)"
  HOME="$h" SUBCON_NO_AUTH_WARNING=1 sub submit docs/t/01-a.md
  assert_rc 0 || return 1
  ! grep -q "consumer" "$T/err" || fail "warning not silenced: $(cat "$T/err")"
  assert_eq "$(jobcount)" 1 jobs
}

test_authwarn_guide_quiet() {
  local h
  h="$(auth_home consumer)"
  HOME="$h" sub guide
  assert_rc 0 || return 1
  ! grep -q "consumer" "$T/err" || fail "guide warned: $(cat "$T/err")"
}

test_authwarn_consumer_resume() {
  local h
  h="$(auth_home consumer)"
  HOME="$h" FAKE_AGY_MODE=error submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  HOME="$h" sub resume "$ID"
  assert_rc 0 || return 1
  grep -q "consumer" "$T/err" || fail "no consumer warning on resume: $(cat "$T/err")"
}

# ---- container (16) --------------------------------------------------------

# engine_bin: a dir holding the fake engine as `docker`, to prepend to PATH.
engine_bin() {
  local d="$T/enginebin"
  mkdir -p "$d"
  ln -sf "$ROOT/tests/fake-engine" "$d/docker"
  printf '%s' "$d"
}

test_container_entry_uses_driver() {
  export FAKE_AGY_MODE=ok
  local d="$T/entry-job" bin="$T/driverbin"
  mkdir -p "$d/work" "$bin"
  ln -s "$ROOT/drivers/agy" "$bin/subcon-driver-agy"
  printf '# t\n\n## Files\n\n- README.md\n\n## Acceptance\n\n- [ ] true\n' > "$d/prompt.txt"
  ( cd "$d/work" && \
    SUBCON_JOB_DIR="$d" \
    SUBCON_PROMPT_FILE="$d/prompt.txt" \
    SUBCON_JOB_MODEL="gemini-3.8-flash-medium" \
    SUBCON_TIMEOUT="30m" \
    SUBCON_SCHEMA="$ROOT/schema/result.schema.json" \
    PATH="$bin:$PATH" \
    "$ROOT/runners/container-entry.sh" ) || fail "container entry failed"
  [[ -s "$d/agy.json" ]] || fail "entry produced no agy.json"
  assert_eq "$(jq -r .status "$d/agy.json")" SUCCESS entry.agy.status
  grep -q 'fake change' "$d/work/README.md" || fail "driver did not run the backend in work"
}

test_container_entry_driver_claude() {
  local d="$T/entry-job-claude" bin="$T/driverbin-claude" fc
  fc="$(fake_claude_path)"
  mkdir -p "$d/work" "$bin"
  ln -s "$ROOT/drivers/claude" "$bin/subcon-driver-claude"
  printf '# t\n\n## Files\n\n- README.md\n\n## Acceptance\n\n- [ ] true\n' > "$d/prompt.txt"
  ( cd "$d/work" && \
    SUBCON_JOB_DIR="$d" \
    SUBCON_DRIVER=claude \
    SUBCON_PROMPT_FILE="$d/prompt.txt" \
    SUBCON_JOB_MODEL="claude-haiku-5-5" \
    SUBCON_TIMEOUT="30m" \
    SUBCON_SCHEMA="$ROOT/schema/result.schema.json" \
    PATH="$bin:$fc:$(clean_path)" \
    "$ROOT/runners/container-entry.sh" ) || fail "container entry (claude) failed"
  [[ -s "$d/agy.json" ]] || fail "entry produced no agy.json"
  assert_eq "$(jq -r .status "$d/agy.json")" SUCCESS entry.agy.status
  assert_eq "$(jq -r .structured_output.summary "$d/agy.json")" "fake claude did it" entry.agy.summary
  grep -q 'fake change' "$d/work/README.md" || fail "claude driver did not run the backend in work"
}

test_container_run_ok() {
  PATH="$(engine_bin):$PATH" FAKE_ENGINE_LOG="$T/engine.log" FAKE_ENGINE_ENTRY="$ROOT/runners/container-entry.sh" \
    sub submit --runner container docs/t/01-a.md
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
  assert_eq "$(jq -r .runner "$(jobdir "$ID")/meta.json")" container meta.runner
  wait_done "$ID" || return 1
  assert_eq "$(result "$ID" .state)" finished state
  assert_eq "$(result "$ID" .status)" done status
  assert_eq "$(result "$ID" .checks.ok)" true checks.ok
  assert_eq "$(result "$ID" -c .checks.files_changed)" '["README.md"]' files_changed
  grep -q '^+fake change$' "$(jobdir "$ID")/patch.diff" || fail "patch lacks the change"
  grep -q "MOUNT $(jobdir "$ID")/work -> /work" "$T/engine.log" || fail "no work mount: $(cat "$T/engine.log")"
  grep -q "MOUNT $(jobdir "$ID") -> /job" "$T/engine.log" || fail "no job mount: $(cat "$T/engine.log")"
  grep -q "ENV SUBCON_PROMPT_FILE=/job/prompt.txt" "$T/engine.log" || fail "no prompt env: $(cat "$T/engine.log")"
  grep -q "ENV SUBCON_SCHEMA=/job/schema.json" "$T/engine.log" || fail "no schema env: $(cat "$T/engine.log")"
  grep -q "RUN name=subcon-$ID " "$T/engine.log" || fail "no run line: $(cat "$T/engine.log")"
  assert_eq "$(worktrees)" 1 worktrees
  assert_eq "$(cat README.md)" base "user tree untouched"
}

test_container_engine_missing() {
  # Since ticket 17, a missing engine is a preflight failure: no job, exit 1.
  SUBCON_CONTAINER_ENGINE=/nonexistent/engine sub run --runner container docs/t/01-a.md
  assert_rc 1 || return 1
  grep -q "engine" "$T/err" || fail "stderr does not mention engine: $(cat "$T/err")"
  assert_eq "$(jobcount)" 0 jobs
}

test_container_api_key_env() {
  PATH="$(engine_bin):$PATH" FAKE_ENGINE_LOG="$T/engine.log" FAKE_ENGINE_ENTRY="$ROOT/runners/container-entry.sh" \
    GEMINI_API_KEY=sk-test-secret sub run --runner container docs/t/01-a.md
  assert_rc 0 || return 1
  assert_eq "$(jget .state)" finished state
  grep -qx "ENV GEMINI_API_KEY" "$T/engine.log" || fail "api key not passed by name: $(cat "$T/engine.log")"
  ! grep -q "sk-test-secret" "$T/engine.log" || fail "api key value leaked into log"
}

test_container_no_api_key_env() {
  PATH="$(engine_bin):$PATH" FAKE_ENGINE_LOG="$T/engine.log" FAKE_ENGINE_ENTRY="$ROOT/runners/container-entry.sh" \
    sub run --runner container docs/t/01-a.md
  assert_rc 0 || return 1
  ! grep -q "GEMINI_API_KEY" "$T/engine.log" || fail "api key env passed while unset: $(cat "$T/engine.log")"
}

test_container_claude_no_key() {
  local fc
  fc="$(fake_claude_path)"
  PATH="$(engine_bin):$fc:$PATH" FAKE_ENGINE_ENTRY="$ROOT/runners/container-entry.sh" ANTHROPIC_API_KEY="" \
    sub submit --runner container --driver claude docs/t/01-a.md
  assert_rc 1 || return 1
  grep -q "ANTHROPIC_API_KEY" "$T/err" || fail "stderr does not mention ANTHROPIC_API_KEY: $(cat "$T/err")"
  assert_eq "$(jobcount)" 0 jobs
}

test_container_claude_run_ok() {
  local fc
  fc="$(fake_claude_path)"
  PATH="$(engine_bin):$fc:$PATH" FAKE_ENGINE_LOG="$T/engine.log" FAKE_ENGINE_ENTRY="$ROOT/runners/container-entry.sh" \
    ANTHROPIC_API_KEY="dummy-anthropic-key-37" sub run --runner container --driver claude docs/t/01-a.md
  assert_rc 0 || return 1
  assert_eq "$(jget .state)" finished state
  assert_eq "$(jget .status)" done status
  ID="$(jget .id)"
  assert_eq "$(jq -r .driver "$(jobdir "$ID")/meta.json")" claude meta.driver
  grep -q "ENV SUBCON_DRIVER=claude" "$T/engine.log" || fail "SUBCON_DRIVER not passed: $(cat "$T/engine.log")"
  grep -qx "ENV ANTHROPIC_API_KEY" "$T/engine.log" || fail "api key not passed by name: $(cat "$T/engine.log")"
  ! grep -q "dummy-anthropic-key-37" "$T/engine.log" || fail "api key value leaked into log"
  grep -q "MOUNT $HOME/.claude -> /home/runner/.claude" "$T/engine.log" || fail "no .claude mount: $(cat "$T/engine.log")"
  ! grep -q "MOUNT $HOME/.gemini" "$T/engine.log" || fail ".gemini mounted for a claude job: $(cat "$T/engine.log")"
}

test_container_resume() {
  PATH="$(engine_bin):$PATH" FAKE_ENGINE_LOG="$T/engine.log" FAKE_ENGINE_ENTRY="$ROOT/runners/container-entry.sh" \
    FAKE_AGY_MODE=error FAKE_AGY_LOG="$T/agy.log" sub submit --runner container docs/t/01-a.md
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
  wait_done "$ID" || return 1
  assert_eq "$(result "$ID" .state)" failed state
  assert_eq "$(result "$ID" .conversation)" conv-fake-1 conversation
  PATH="$(engine_bin):$PATH" FAKE_ENGINE_LOG="$T/engine.log" FAKE_ENGINE_ENTRY="$ROOT/runners/container-entry.sh" \
    FAKE_AGY_LOG="$T/agy.log" sub resume "$ID"
  assert_rc 0 || return 1
  local new
  new="$(jget '.[0].id')"
  wait_done "$new" || return 1
  assert_eq "$(result "$new" .state)" finished state
  assert_eq "$(jq -r .runner "$(jobdir "$new")/meta.json")" container meta.runner
  grep -q -- "--conversation conv-fake-1" "$T/agy.log" || fail "no --conversation: $(cat "$T/agy.log")"
}

test_container_clone_layout() {
  PATH="$(engine_bin):$PATH" FAKE_ENGINE_ENTRY="$ROOT/runners/container-entry.sh" FAKE_AGY_MODE=layout \
    sub run --runner container docs/t/01-a.md
  assert_rc 0 || return 1
  assert_eq "$(jget .state)" finished state || return 1
  grep -q "git-layout: clone" "$(jget .patch)" || fail "patch does not show clone layout: $(cat "$(jget .patch)")"
}

# ---- cijob (19) --------------------------------------------------------------

ci_fixture() {
  local dest="$T/cirepo"
  rm -rf "$dest"
  mkdir -p "$dest/docs/t"
  echo base > "$dest/README.md"
  cp "$T/repo/docs/t/01-a.md" "$dest/docs/t/01-a.md" 2>/dev/null || printf '# a\n\n## Goal\ng\n\n## Files\n- README.md\n\n## Acceptance\n- `true`\n' > "$dest/docs/t/01-a.md"
  git -C "$dest" init -q
  git -C "$dest" config user.name t
  git -C "$dest" config user.email t@example.invalid
  git -C "$dest" add -A
  git -C "$dest" commit -qm init
  CI_BASE="$(git -C "$dest" rev-parse HEAD)"
}

test_cijob_ok() {
  ci_fixture
  RC=0
  RUNNER_TEMP="$T/rt" GITHUB_WORKSPACE="$T/cirepo" \
    SUBCON_CI_JOB=testjob1 SUBCON_CI_TICKET=docs/t/01-a.md SUBCON_CI_BASE="$CI_BASE" \
    SUBCON_CI_MODEL=fake SUBCON_CI_TIMEOUT=5m \
    bash "$ROOT/ci/run-job.sh" > "$T/out" 2> "$T/err" || RC=$?
  assert_rc 0 || return 1
  local art="$T/rt/subcon-testjob1/artifact"
  [[ -f "$art/work.tar.gz" && -f "$art/agy.json" ]] || fail "artifact incomplete: $(ls "$art" 2>/dev/null)"
  grep -q '"SUCCESS"' "$art/agy.json" || fail "agy.json has no SUCCESS: $(cat "$art/agy.json")"
  mkdir -p "$T/unpacked" && tar -xzf "$art/work.tar.gz" -C "$T/unpacked"
  grep -q "fake change" "$T/unpacked/work/README.md" || fail "work tar lacks the fake change"
}

test_cijob_claude_ok() {
  ci_fixture
  local fc h
  fc="$(fake_claude_path)"
  h="$T/cihome"
  mkdir -p "$h"
  RC=0
  HOME="$h" PATH="$fc:$PATH" RUNNER_TEMP="$T/rt" GITHUB_WORKSPACE="$T/cirepo" \
    CLAUDE_CODE_OAUTH_TOKEN="dummy-token-38" \
    SUBCON_CI_JOB=testjob3 SUBCON_CI_TICKET=docs/t/01-a.md SUBCON_CI_BASE="$CI_BASE" \
    SUBCON_CI_MODEL=claude-haiku-5-5 SUBCON_CI_TIMEOUT=5m SUBCON_CI_DRIVER=claude \
    bash "$ROOT/ci/run-job.sh" > "$T/out" 2> "$T/err" || RC=$?
  assert_rc 0 || return 1
  local art="$T/rt/subcon-testjob3/artifact"
  [[ -f "$art/work.tar.gz" && -f "$art/agy.json" ]] || fail "artifact incomplete: $(ls "$art" 2>/dev/null)"
  grep -q 'fake claude did it' "$art/agy.json" || fail "agy.json is not the claude driver's result: $(cat "$art/agy.json")"
  mkdir -p "$T/unpacked3" && tar -xzf "$art/work.tar.gz" -C "$T/unpacked3"
  grep -q "fake change" "$T/unpacked3/work/README.md" || fail "work tar lacks the fake change"
}

test_cijob_claude_env_file() {
  ci_fixture
  local fc h
  fc="$(fake_claude_path)"
  h="$T/cihome-file"
  mkdir -p "$h/.config/subcon"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=dummy-from-file\n' > "$h/.config/subcon/claude-env"
  RC=0
  HOME="$h" PATH="$fc:$PATH" RUNNER_TEMP="$T/rt" GITHUB_WORKSPACE="$T/cirepo" \
    SUBCON_CI_JOB=testjob4 SUBCON_CI_TICKET=docs/t/01-a.md SUBCON_CI_BASE="$CI_BASE" \
    SUBCON_CI_MODEL=claude-haiku-5-5 SUBCON_CI_TIMEOUT=5m SUBCON_CI_DRIVER=claude \
    bash "$ROOT/ci/run-job.sh" > "$T/out" 2> "$T/err" || RC=$?
  assert_rc 0 || return 1
  local art="$T/rt/subcon-testjob4/artifact"
  [[ -f "$art/agy.json" ]] || fail "no agy.json artifact: $(ls "$art" 2>/dev/null)"
  grep -q 'fake claude did it' "$art/agy.json" || fail "agy.json is not the claude driver's result: $(cat "$art/agy.json")"
}

test_cijob_claude_no_credentials() {
  ci_fixture
  local fc h
  fc="$(fake_claude_path)"
  h="$T/cihome-none"
  mkdir -p "$h"
  RC=0
  HOME="$h" PATH="$fc:$PATH" RUNNER_TEMP="$T/rt" GITHUB_WORKSPACE="$T/cirepo" \
    SUBCON_CI_JOB=testjob5 SUBCON_CI_TICKET=docs/t/01-a.md SUBCON_CI_BASE="$CI_BASE" \
    SUBCON_CI_MODEL=claude-haiku-5-5 SUBCON_CI_TIMEOUT=5m SUBCON_CI_DRIVER=claude \
    bash "$ROOT/ci/run-job.sh" > "$T/out" 2> "$T/err" || RC=$?
  [[ $RC -eq 1 ]] || fail "expected exit 1, got $RC"
  grep -q "claude-env" "$T/err" || fail "stderr lacks the env-file hint: $(cat "$T/err")"
  [[ ! -f "$T/rt/subcon-testjob5/artifact/agy.json" ]] || fail "agy.json produced without credentials"
}

test_cijob_fail_still_packages() {
  ci_fixture
  RC=0
  RUNNER_TEMP="$T/rt" GITHUB_WORKSPACE="$T/cirepo" FAKE_AGY_MODE=fail \
    SUBCON_CI_JOB=testjob2 SUBCON_CI_TICKET=docs/t/01-a.md SUBCON_CI_BASE="$CI_BASE" \
    SUBCON_CI_MODEL=fake SUBCON_CI_TIMEOUT=5m \
    bash "$ROOT/ci/run-job.sh" > "$T/out" 2> "$T/err" || RC=$?
  [[ $RC -ne 0 ]] || fail "expected nonzero exit, got 0"
  local art="$T/rt/subcon-testjob2/artifact"
  [[ -f "$art/work.tar.gz" ]] || fail "work.tar.gz missing on failure"
  [[ ! -f "$art/agy.json" ]] || fail "agy.json should not exist when agy produced no result"
}

# ---- cirunner (20) -----------------------------------------------------------

gh_bin() {
  local d="$T/bin"
  mkdir -p "$d"
  cp "$ROOT/tests/fake-agy" "$d/agy"
  cp "$ROOT/tests/fake-gh" "$d/gh"
  chmod +x "$d/agy" "$d/gh"
  echo "$d"
}

test_cirunner_ok() {
  mkdir -p "$T/repo/.github/workflows" && touch "$T/repo/.github/workflows/subcon-job.yml"
  PATH="$(gh_bin):$PATH" FAKE_GH_STATE="$T/ghstate" FAKE_GH_WORKSPACE="$T/repo" FAKE_GH_SUBCON_ROOT="$ROOT" SUBCON_CI_POLL=1 \
    sub run --runner ci docs/t/01-a.md
  assert_rc 0 || return 1
  assert_eq "$(jget .state)" finished state || return 1
  assert_eq "$(jget .status)" done status || return 1
  assert_eq "$(jget -r '.checks.files_changed | join(",")')" "README.md" files_changed || return 1
  grep -q "fake change" "$(jget .patch)" || fail "patch lacks the fake change: $(cat "$(jget .patch)")"
}

test_cirunner_claude_ok() {
  mkdir -p "$T/repo/.github/workflows" && touch "$T/repo/.github/workflows/subcon-job.yml"
  local fc
  fc="$(fake_claude_path)"
  PATH="$(gh_bin):$fc:$PATH" FAKE_GH_STATE="$T/ghstate" FAKE_GH_WORKSPACE="$T/repo" FAKE_GH_SUBCON_ROOT="$ROOT" SUBCON_CI_POLL=1 \
    CLAUDE_CODE_OAUTH_TOKEN="dummy-token-38" \
    sub run --runner ci --driver claude docs/t/01-a.md
  assert_rc 0 || return 1
  assert_eq "$(jget .state)" finished state || return 1
  assert_eq "$(jget .status)" done status || return 1
  assert_eq "$(jget -r '.checks.files_changed | join(",")')" "README.md" files_changed || return 1
  grep -q "fake change" "$(jget .patch)" || fail "patch lacks the fake change: $(cat "$(jget .patch)")"
}

test_cirunner_foreign_owner() {
  mkdir -p "$T/repo/.github/workflows" && touch "$T/repo/.github/workflows/subcon-job.yml"
  # The ownership failure only bites on filesystems that refuse chown (the
  # production state dir lives on one under $HOME); /tmp allows it, so run
  # this job with its state under $HOME and clean up afterwards.
  local hstate st has=0
  hstate="$(mktemp -d "$HOME/subcon-test-state.XXXXXX")"
  PATH="$(gh_bin):$PATH" FAKE_GH_STATE="$T/ghstate" FAKE_GH_WORKSPACE="$T/repo" FAKE_GH_SUBCON_ROOT="$ROOT" SUBCON_CI_POLL=1 \
    FAKE_GH_FOREIGN_OWNER=1 SUBCON_STATE="$hstate" \
    sub run --runner ci docs/t/01-a.md
  st="$(jget .state)"
  [[ -f "$hstate/jobs/$(jget .id)/agy.json" ]] && has=1
  chmod -R u+rwX "$hstate" 2>/dev/null || true
  rm -rf "$hstate"
  assert_rc 0 || return 1
  assert_eq "$st" finished state || return 1
  [[ $has -eq 1 ]] || fail "agy.json not restored to the job dir"
}

test_cirunner_workflow_failure() {
  mkdir -p "$T/repo/.github/workflows" && touch "$T/repo/.github/workflows/subcon-job.yml"
  PATH="$(gh_bin):$PATH" FAKE_GH_STATE="$T/ghstate" FAKE_GH_WORKSPACE="$T/repo" FAKE_GH_SUBCON_ROOT="$ROOT" SUBCON_CI_POLL=1 \
    FAKE_GH_CONCLUSION=failure FAKE_AGY_MODE=fail \
    sub run --runner ci docs/t/01-a.md
  assert_rc 4 || return 1
  assert_eq "$(jget .state)" failed state
}

# ---- cipre (21) ---------------------------------------------------------------

test_cipre_gh_missing() {
  local d="$T/bin" f n
  mkdir -p "$d"
  cp "$ROOT/tests/fake-agy" "$d/agy"
  chmod +x "$d/agy"
  # A PATH of everything except gh: some systems ship gh in /usr/bin, so a
  # bare restricted PATH cannot be trusted to hide it.
  for f in /usr/bin/* /bin/*; do
    n="$(basename "$f")"
    [[ "$n" == gh ]] || ln -s "$f" "$d/$n" 2>/dev/null || true
  done
  PATH="$d" sub submit --runner ci docs/t/01-a.md
  assert_rc 1 || return 1
  grep -q "gh" "$T/err" || fail "stderr does not mention gh: $(cat "$T/err")"
  assert_eq "$(jobcount)" 0 jobs
}

test_cipre_no_auth() {
  PATH="$(gh_bin):$PATH" FAKE_GH_NO_AUTH=1 sub submit --runner ci docs/t/01-a.md
  assert_rc 1 || return 1
  grep -qi "auth" "$T/err" || fail "stderr does not mention auth: $(cat "$T/err")"
  assert_eq "$(jobcount)" 0 jobs
}

test_cipre_no_workflow() {
  PATH="$(gh_bin):$PATH" sub submit --runner ci docs/t/01-a.md
  assert_rc 1 || return 1
  grep -q "workflow" "$T/err" || fail "stderr does not mention workflow: $(cat "$T/err")"
  assert_eq "$(jobcount)" 0 jobs
}

test_cipre_ok() {
  mkdir -p "$T/repo/.github/workflows"
  touch "$T/repo/.github/workflows/subcon-job.yml"
  PATH="$(gh_bin):$PATH" sub submit --runner ci docs/t/01-a.md
  assert_rc 0 || return 1
  assert_eq "$(jobcount)" 1 jobs
}

# ---- containerpre (17) -----------------------------------------------------

test_containerpre_engine_missing() {
  SUBCON_CONTAINER_ENGINE=/nonexistent/engine sub submit --runner container docs/t/01-a.md
  assert_rc 1 || return 1
  grep -q "engine" "$T/err" || fail "stderr does not mention engine: $(cat "$T/err")"
  assert_eq "$(jobcount)" 0 jobs
}

test_containerpre_image_missing() {
  PATH="$(engine_bin):$PATH" FAKE_ENGINE_NO_IMAGE=1 sub submit --runner container docs/t/01-a.md
  assert_rc 1 || return 1
  grep -q "image" "$T/err" || fail "stderr does not mention image: $(cat "$T/err")"
  assert_eq "$(jobcount)" 0 jobs
}

test_containerpre_ok() {
  PATH="$(engine_bin):$PATH" FAKE_ENGINE_ENTRY="$ROOT/runners/container-entry.sh" \
    sub submit --runner container docs/t/01-a.md
  assert_rc 0 || return 1
  assert_eq "$(jobcount)" 1 jobs
}

test_containerpre_local_unaffected() {
  SUBCON_CONTAINER_ENGINE=/nonexistent/engine sub submit docs/t/01-a.md
  assert_rc 0 || return 1
  assert_eq "$(jobcount)" 1 jobs
}

# ---- formats (25) ----------------------------------------------------------

test_formats_meta_v() {
  submit_one docs/t/01-a.md || return 1
  assert_eq "$(jq -r .v "$(jobdir "$ID")/meta.json")" 1 meta.v
}

test_formats_result_v() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  assert_eq "$(result "$ID" .v)" 1 result.v
  assert_eq "$(jq -r .v "$(jobdir "$ID")/result.json")" 1 result_file.v
}

test_formats_running_result_v() {
  export FAKE_AGY_MODE=sleep FAKE_AGY_SLEEP=6
  submit_one docs/t/01-a.md || return 1
  sub show "$ID"
  assert_rc 0 || return 1
  assert_eq "$(jget .v)" 1 running.v
  assert_match "$(jget .state)" '^(queued|running)$' running.state
  wait_done "$ID" || return 1
}

test_formats_history_v() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  assert_eq "$(jq -r --arg id "$ID" 'select(.type == "job" and .id == $id) | .v' "$(hist)")" 1 history_job.v
  sub apply "$ID"
  assert_rc 0 || return 1
  assert_eq "$(jq -r --arg id "$ID" 'select(.type == "event" and .id == $id) | .v' "$(hist)")" 1 history_event.v
}

test_formats_legacy_without_v() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  local d
  d="$(jobdir "$ID")"
  jq 'del(.v)' "$d/meta.json" > "$T/meta.tmp" && mv "$T/meta.tmp" "$d/meta.json"
  jq 'del(.v)' "$d/result.json" > "$T/result.tmp" && mv "$T/result.tmp" "$d/result.json"
  jq -c 'del(.v)' "$(hist)" > "$T/hist.tmp" && mv "$T/hist.tmp" "$(hist)"
  sub show "$ID"
  assert_rc 0 || return 1
  assert_eq "$(jget .id)" "$ID" legacy.show_id
  sub stats > /dev/null
  assert_rc 0 || return 1
}

# ---- runnerenv (26) --------------------------------------------------------

test_runnerenv_container_env() {
  PATH="$(engine_bin):$PATH" FAKE_ENGINE_LOG="$T/engine.log" FAKE_ENGINE_ENTRY="$ROOT/runners/container-entry.sh" \
    sub submit --runner container --model env-model-1 docs/t/01-a.md
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
  wait_done "$ID" || return 1
  assert_eq "$(result "$ID" .status)" done status
  grep -q "ENV SUBCON_JOB_MODEL=env-model-1" "$T/engine.log" || fail "no SUBCON_JOB_MODEL env: $(cat "$T/engine.log")"
  grep -q "ENV SUBCON_MODEL=" "$T/engine.log" && fail "legacy SUBCON_MODEL still passed: $(cat "$T/engine.log")"
  return 0
}

test_runnerenv_local_flags() {
  export FAKE_AGY_LOG="$T/agy.log"
  submit_one --model flag-model-2 docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  grep -q -- "--model flag-model-2" "$T/agy.log" || fail "model did not reach agy: $(cat "$T/agy.log")"
}

test_runnerenv_user_knob() {
  SUBCON_MODEL=knob-model sub submit docs/t/01-a.md
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
  assert_eq "$(jq -r .model "$(jobdir "$ID")/meta.json")" knob-model meta.model
}

# ---- entry (28) ------------------------------------------------------------

test_entry_run_two_tickets() {
  write_ticket docs/t/02-b.md README.md
  commit_all second
  sub run docs/t/01-a.md docs/t/02-b.md
  assert_rc 1 || return 1
  assert_eq "$(jobcount)" 0 jobs
}

test_entry_resume_ci_refused() {
  mkdir -p "$T/repo/.github/workflows" && touch "$T/repo/.github/workflows/subcon-job.yml"
  PATH="$(gh_bin):$PATH" FAKE_GH_STATE="$T/ghstate" FAKE_GH_WORKSPACE="$T/repo" FAKE_GH_SUBCON_ROOT="$ROOT" SUBCON_CI_POLL=1 \
    sub submit --runner ci docs/t/01-a.md
  assert_rc 0 || return 1
  ID="$(jget '.[0].id')"
  wait_done "$ID" || return 1
  sub resume "$ID"
  assert_rc 1 || return 1
  grep -q "resume is not supported for the ci runner" "$T/err" || fail "stderr: $(cat "$T/err")"
  assert_eq "$(jobcount)" 1 jobs
}

test_entry_trailer_unknown_option() {
  sub trailer --foo
  assert_rc 1 || return 1
  grep -q "unknown option" "$T/err" || fail "stderr: $(cat "$T/err")"
}

test_entry_trailer_model_needs_value() {
  sub trailer --model
  assert_rc 1 || return 1
  grep -q -- "--model requires a value" "$T/err" || fail "stderr: $(cat "$T/err")"
}

test_entry_trailer_ok() {
  sub trailer --model gemini-3.8-flash-medium
  assert_rc 0 || return 1
  grep -q "Co-Authored-By: Gemini 3.8 Flash" <<<"$OUT" || fail "stdout: $OUT"
}

# ---- guard (29) --------------------------------------------------------------

test_guard_commit_not_applied() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  echo "unrelated edit" >> README.md
  local before
  before="$(git rev-parse HEAD)"
  SUBCON_REVIEWER="$REVIEWER" sub commit -m "feat: x" "$ID"
  assert_rc 1 || return 1
  grep -q "not applied" "$T/err" || fail "stderr: $(cat "$T/err")"
  assert_eq "$(git rev-parse HEAD)" "$before" head_unchanged
  grep -q "unrelated edit" README.md || fail "working tree edit lost"
}

test_guard_commit_edited_allows() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub apply "$ID"
  assert_rc 0 || return 1
  echo "supervisor fix" >> README.md
  SUBCON_REVIEWER="$REVIEWER" sub commit -m "feat: x" --edited "$ID"
  assert_rc 0 || return 1
}

test_guard_commit_twice() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub apply "$ID"
  assert_rc 0 || return 1
  SUBCON_REVIEWER="$REVIEWER" sub commit -m "feat: x" "$ID"
  assert_rc 0 || return 1
  local before
  before="$(git rev-parse HEAD)"
  echo "another edit" >> README.md
  SUBCON_REVIEWER="$REVIEWER" sub commit -m "feat: y" "$ID"
  assert_rc 1 || return 1
  grep -q "already committed" "$T/err" || fail "stderr: $(cat "$T/err")"
  assert_eq "$(git rev-parse HEAD)" "$before" head_unchanged
}

test_guard_commit_agy_missing_clean_index() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub apply "$ID"
  assert_rc 0 || return 1
  local cp h
  cp="$(clean_path)"
  h="$(preflight_home no-agy)"
  HOME="$h" PATH="$cp" SUBCON_REVIEWER="$REVIEWER" sub commit -m "feat: x" "$ID"
  assert_rc 1 || return 1
  git diff --cached --quiet || fail "index was staged before the failure"
}

test_guard_reject_bad_runner_no_side_effects() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  local before
  before="$(git rev-parse HEAD)"
  sub reject -m "bad runner" --runner no-such-runner "$ID"
  assert_rc 1 || return 1
  assert_eq "$(git rev-parse HEAD)" "$before" head_unchanged
  assert_eq "$(git status --porcelain -- docs/t/01-a.md)" "" ticket_untouched
  grep -q '"event":"rejected"' "$(hist)" && fail "rejected event recorded"
  return 0
}

test_guard_reject_agy_missing_no_side_effects() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  local before cp h
  before="$(git rev-parse HEAD)"
  cp="$(clean_path)"
  h="$(preflight_home no-agy)"
  HOME="$h" PATH="$cp" sub reject -m "no agy" "$ID"
  assert_rc 1 || return 1
  assert_eq "$(git rev-parse HEAD)" "$before" head_unchanged
  assert_eq "$(git status --porcelain -- docs/t/01-a.md)" "" ticket_untouched
}

test_guard_reject_cap_ignores_resume() {
  mkdir -p "$SUBCON_STATE"
  local i
  for i in 1 2; do
    jq -cn --arg repo "$TOP" --arg ticket "docs/t/01-a.md" --arg id "seed$i" '
      {type: "job", v: 1, id: $id, repo: $repo, ticket: $ticket,
       model: "m", runner: "local", created_at: "2026-01-01T00:00:00Z",
       finished_at: "2026-01-01T00:01:00Z", duration_s: 1, state: "finished",
       status: "done", checks_ok: true, files_changed: 1, insertions: 1,
       deletions: 0, tokens: null, resume_of: "seed-parent"}
    ' >> "$(hist)"
  done
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  sub reject -m "cap check" "$ID"
  assert_rc 0 || return 1
  assert_eq "$(jobcount)" 2 jobs
}

# ---- logcmd (ticket 31) ----------------------------------------------------

test_logcmd_prints_log() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  echo "marker-line-xyz" >> "$(jobdir "$ID")/log"
  sub log "$ID"
  assert_rc 0 || return 1
  assert_match "$OUT" "marker-line-xyz" log_content
}

test_logcmd_missing_log() {
  submit_one docs/t/01-a.md || return 1
  wait_done "$ID" || return 1
  rm -f "$(jobdir "$ID")/log"
  sub log "$ID"
  assert_rc 1 || return 1
  grep -q "no log" "$T/err" || fail "stderr: $(cat "$T/err")"
}

test_logcmd_unknown_id() {
  sub log 20990101-000000-nope-0000
  assert_rc 1 || return 1
  grep -q "unknown job id" "$T/err" || fail "stderr: $(cat "$T/err")"
}

test_logcmd_no_args() {
  sub log
  assert_rc 1 || return 1
}

# ---- budget (46) -----------------------------------------------------------

test_budget_tokens_exceeded() {
  mkdir -p "$SUBCON_STATE"
  hjob A "$TOP" m1 finished done true 10 80 20
  SUBCON_BUDGET_TOKENS=100 sub submit docs/t/01-a.md
  assert_rc 1 || return 1
  grep -q "SUBCON_BUDGET_TOKENS" "$T/err" || fail "stderr: $(cat "$T/err")"
  assert_eq "$(jobcount)" 0 jobs
}

test_budget_tokens_under() {
  mkdir -p "$SUBCON_STATE"
  hjob A "$TOP" m1 finished done true 10 80 20
  SUBCON_BUDGET_TOKENS=101 sub submit docs/t/01-a.md
  assert_rc 0 || return 1
  assert_eq "$(jobcount)" 1 jobs
}

test_budget_jobs_exceeded() {
  mkdir -p "$SUBCON_STATE"
  hjob A "$TOP" m1 finished done true 10 80 20
  hjob B "$TOP" m1 finished done true 10 80 20
  SUBCON_BUDGET_JOBS=2 sub submit docs/t/01-a.md
  assert_rc 1 || return 1
  grep -q "SUBCON_BUDGET_JOBS" "$T/err" || fail "stderr: $(cat "$T/err")"
  assert_eq "$(jobcount)" 0 jobs
}

test_budget_old_month_ignored() {
  mkdir -p "$SUBCON_STATE"
  hjob A "$TOP" m1 finished done true 10 99980 20 40
  SUBCON_BUDGET_TOKENS=10 sub submit docs/t/01-a.md
  assert_rc 0 || return 1
  assert_eq "$(jobcount)" 1 jobs
}

test_budget_run_blocked() {
  mkdir -p "$SUBCON_STATE"
  hjob A "$TOP" m1 finished done true 10 80 20
  SUBCON_BUDGET_TOKENS=100 sub run docs/t/01-a.md
  assert_rc 1 || return 1
  grep -q "SUBCON_BUDGET_TOKENS" "$T/err" || fail "stderr: $(cat "$T/err")"
  assert_eq "$(jobcount)" 0 jobs
}

test_budget_invalid_value() {
  SUBCON_BUDGET_TOKENS=abc sub submit docs/t/01-a.md
  assert_rc 1 || return 1
  grep -q "SUBCON_BUDGET_TOKENS" "$T/err" || fail "stderr: $(cat "$T/err")"
  assert_eq "$(jobcount)" 0 jobs
}

# ---- runner --------------------------------------------------------------

groups=("$@")
[[ ${#groups[@]} -gt 0 ]] || groups=(ticket submit query manage commit checks reject formats runnerenv entry guard logcmd history stats export resume preflight authwarn container containerpre cijob cirunner cipre driver budget)

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
