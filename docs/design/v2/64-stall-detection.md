# 64. Stall detection and manual finish

## Problem

`job_result` treats a live runner PID as proof of progress. A driver that
finished its work but hangs before exiting (stream teardown, report stage,
network stall) keeps `state=running` forever: `wait` spins until `--timeout`,
and there is no way to collect the finished `work/` diff without `discard`
(which deletes the whole job).

## Design

### `activity_age` in `job_result`

For `queued`/`running` jobs the result JSON gains `activity_age`: seconds
since the newest write under the job dir (top-level artifacts plus the whole
`work/` tree, `.git`/`node_modules` pruned). `-1` when nothing is datable.
Computed by `job_activity_age` in `lib/common.sh` (portable `stat` flavor
detected once per call; ~50 ms on a large worktree).

### `subcon wait --stall-after <dur>`

Same duration syntax as `--timeout` (`N`, `Ns`, `Nm`, `Nh`). Each poll, after
the all-done and timeout checks: if every unfinished job has
`activity_age > stall_after` (or `-1`), `wait` returns early with the current
results and a stderr note. A single progressing job keeps the wait alive.
Return code stays `exit_code_for`-based; callers detect the early return via
the stderr note and the `activity_age` field. Default `0` = disabled.

### `subcon finish <id>`

Manually close a stuck local-runner job and keep its artifacts:

1. `job_result` first, so a dead runner is already settled to `failed`.
2. Die unless state is `queued`/`running` and `meta.runner == "local"`.
3. Read `pid`; verify via `ps -o command=` that it is this job's
   `subcon __exec <dir>` before signalling (guards PID reuse).
4. `TERM` the wrapper: its trap kills the runner tree and its `EXIT` trap
   runs `job_finalize` → `failed` + `patch.diff` from `work/`.
5. Wait up to 15 s for a terminal state; if none, `KILL` the wrapper and its
   direct children, then `job_finalize "$dir" died` directly (idempotent).
6. Print the final `job_result` JSON.

`finish` never deletes the job dir; `patch.diff`, `result.json`, and history
survive, so `subcon diff/apply` work on the collected work.

## Out of scope

- Automatic killing on stall (detection only; the human decides).
- `container`/`ci` runners (no verified local cleanup path yet).
- Fixing PID-reuse liveness in `job_result` itself.

## Tests

- `wait --stall-after` returns early on an idle job, stays for an active one.
- `finish` on a sleeping fake-agy job yields `failed` + `patch.diff`.
- `finish` on a finished job dies with a clear message.
- `activity_age` appears and is small right after submit, large after aging.
