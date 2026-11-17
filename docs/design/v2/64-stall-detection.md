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
results and a stderr note. Default `0` = disabled.

Only `state=running` jobs with `runner=local` are stall-eligible: ci and
container jobs do their work off-box (local files stay static while
healthy) and queued jobs have not started, so either one blocks the early
return rather than counting as stalled. Ages come from the `activity_age`
field `job_result` already computed in the same poll (no rescan).

### `subcon finish <id>`

Manually close a stuck local-runner job and keep its artifacts:

1. `job_result` first, so a dead runner is already settled to `failed`.
2. Die unless state is `queued`/`running` and `meta.runner == "local"`.
3. Read `pid`; verify via `ps -o command=` that it is this job's
   `subcon __exec <dir>` before signalling (guards PID reuse).
4. `TERM` the wrapper: its trap kills the runner tree and its `EXIT` trap
   runs `job_finalize` → `failed` + `patch.diff` from `work/`.
5. Wait up to 15 s for a terminal state, then up to 10 s more for the
   wrapper pid to exit (`job_finalize` writes `state` before removing the
   worktree, so terminal state alone does not mean cleanup finished).
6. If still not terminal, `KILL` the whole descendant tree
   (`pid_descendants`; grandchildren like agy would otherwise be orphaned
   inside `work/`) and call `job_finalize "$dir" died` directly
   (idempotent).
7. Print the final `job_result` JSON with `exit_code_for` semantics.

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
