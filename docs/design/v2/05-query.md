# wait / show / run

## Goal
ジョブの結果を待つ・表示するコマンドと、ランナー消失の検出を実装する。

## Files
- lib/query.sh

## Interface
`lib/query.sh` に次を実装する（02 で空実装が置いてある）。仕様は `docs/design/v2.md` のコマンド表・オプション・終了コード・「結果」節。

- `job_result <id>`: 結果 JSON を 1 件出す
  - ジョブディレクトリが無ければ終了コード 1
  - `state` が `queued`/`running` で、`pid` のプロセスが居なければ `job_finalize <dir> died` を呼んでから結果を出す
  - `queued`/`running` なら `{id, repo, ticket, state}` 以外を `null` にした結果
  - それ以外は `result.json` の内容
- `cmd_show <id>`: `job_result` を出す。終了コードは結果に対する終了コード（0/2/3/4、実行中なら 0）
- `cmd_wait [--timeout SEC] <id>...`: 0.5 秒間隔で全ジョブの終了を待ち、結果の配列を出す。未知の ID は待つ前に終了コード 1。タイムアウト時はその時点の配列を出して 5
- `cmd_run [submit の opts] <ticket>`: `cmd_submit` を呼び、得た ID で `cmd_wait`（タイムアウトなし）。出力は結果 1 件（配列でなくオブジェクト）。submit が失敗したらその終了コード
- `exit_code_for <result-json>`: 結果 1 件から終了コード（0/2/3/4）を決める。配列なら最大値

## Acceptance
- `tests/run.sh query`

## Notes
- 04 の `lib/job.sh` は編集しない。必要な関数は呼び出すだけ。
- `bin/subcon`、`lib/common.sh`、`tests/` は編集しない。
