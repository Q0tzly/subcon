# list / diff / apply / discard

## Goal
発行済みジョブを一覧・確認・適用・削除するコマンドを実装する。

## Files
- lib/manage.sh

## Interface
`lib/manage.sh` に次を実装する（02 で空実装が置いてある）。仕様は `docs/design/v2.md` のコマンド表と「apply」「discard」節。

- `cmd_list [--all]`: `[{id, repo, ticket, state, status, created_at}]` を `created_at` の新しい順。`--all` が無ければ `repo` が今のリポジトリのトップと一致するものだけ。ジョブが無ければ `[]`
- `cmd_diff <id>`: `patch.diff` をそのまま stdout へ。無ければ終了コード 1
- `cmd_apply <id>`: 「apply」節の 1〜4 のとおり。成功時 `{"id": "<id>", "applied": true}`
- `cmd_discard <id>...`: 「discard」節のとおり。成功時 `{"discarded": [<id>...]}`

## Acceptance
- `tests/run.sh manage`

## Notes
- `state` の判定は `lib/query.sh` の `job_result` を通す（ランナー消失の検出を共有するため）。
- `lib/job.sh`、`lib/query.sh`、`bin/subcon`、`lib/common.sh`、`tests/` は編集しない。
- macOS の `/bin/bash` 3.2 で動くこと（連想配列・`mapfile`・`${x,,}` は使わない。`set -u` 下で空配列を `"${a[@]}"` と展開しない）。
