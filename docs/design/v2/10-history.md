# 使用履歴の記録

## Goal
ジョブの終了と `apply` の成功を `history.jsonl` に 1 行ずつ追記する。`discard` でジョブを消しても履歴は残る。

## Files
- lib/history.sh

## Interface
`lib/history.sh` の次の 2 関数を実装する（空実装が置いてある。名前と引数は変えない。`history_file` はそのまま使う）。
呼び出し側（`lib/job.sh` の `job_finalize`、`lib/manage.sh` の `cmd_apply`）は実装済みで、サブシェルで呼ぶ。

- `history_append_job <job-dir>`: `job_finalize` が `result.json` を書いた直後に呼ばれる。次の 1 行を追記する
  ```
  {type: "job", id, repo, ticket, model, runner, created_at, finished_at, duration_s,
   state, status, checks_ok, files_changed, insertions, deletions, tokens, resume_of}
  ```
  - `id` `repo` `ticket` `model` `runner` `created_at`: `meta.json` から
  - `finished_at`: 今の UTC 時刻 `YYYY-MM-DDTHH:MM:SSZ`
  - `state` `status`: `result.json` から（`status` は null あり）
  - `checks_ok`: `result.json` の `.checks.ok`。`checks` が null なら null
  - `files_changed`: `.checks.files_changed` の要素数。`checks` が null なら null
  - `insertions` `deletions`: `result.json` の `diffstat`（例 `1 file changed, 3 insertions(+), 1 deletion(-)`）から数を取る。片方の記述が無ければ 0。`diffstat` が空文字なら両方 0。`diffstat` が null なら両方 null
  - `duration_s`: `agy.json` の `.duration_seconds`。`agy.json` が無い・読めない・値が無いなら null
  - `tokens`: `agy.json` の `.usage` があれば `{input: .input_tokens, output: .output_tokens, total: .total_tokens}`、無ければ null
  - `resume_of`: `meta.json` の `.resume_of`。無ければ null
- `history_append_event <id> <event>`: `{type: "event", id, event, at}` を追記する。`at` は今の UTC 時刻（形式は上と同じ）

追記の約束:
- 1 行 = 1 つのコンパクトな JSON（`jq -c`）。末尾に改行
- 複数のジョブが同時に終わっても行が混ざらないこと。`mkdir "$(history_file).lock"` を排他ロックにして（取れなければ 0.1 秒待って再試行、最大 50 回）、取れたら追記して `rmdir` する。取れなければ stderr に書いて 1 を返す
- `state_root` のディレクトリが無ければ作る

## Acceptance
- `tests/run.sh history`
- `tests/run.sh`（既存のテストも全部通ること）

## Notes
- 時刻は `date -u +%Y-%m-%dT%H:%M:%SZ`。
- `lib/history.sh` 以外は編集しない（特に `tests/`、`lib/job.sh`、`lib/manage.sh`）。
- macOS の `/bin/bash` 3.2 で動くこと（連想配列・`mapfile`・`${x,,}` は使わない。`set -u` 下で空配列を `"${a[@]}"` と展開しない）。
