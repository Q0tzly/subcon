# submit とバックグラウンド実行

## Goal
票からジョブを作り、worktree でランナーをバックグラウンド実行し、終了時にパッチと `result.json` を残す。

## Files
- lib/job.sh
- runners/local

## Interface
`docs/design/v2.md` の「ジョブ」節（保存場所・ID・結果・流れ）と「ランナー契約」節を、次の関数で実装する（02 で空実装が置いてある）。

- `cmd_submit [--runner R] [--model M] [--timeout T] <ticket>...`
  - オプションの既定と検証は「オプション」節のとおり。未知のオプション・票なしは終了コード 1
  - 全票を `ticket_validate` で先に検証し、1 枚でも失敗したら何も作らず終了コード 1
  - stdout: `[{"ticket": "...", "id": "..." , "error": null}, ...]`。起動に失敗した票は `"id": null` と `"error": "<理由>"`。1 件でも失敗があれば終了コード 4、なければ 0
- `job_exec <job-dir>`: バックグラウンドで動く本体。`state=running` → ランナー実行 → 後処理。`trap` でどの終わり方でも後処理する。`cmd_submit` は `nohup "$SUBCON_ROOT/bin/subcon" __exec <job-dir> &` で起動する（`__exec` の振り分けは 02 で用意済み）
- `job_finalize <job-dir> <runner-exit-code>`: 後処理。パッチ・チェック・`result.json`・`state`・worktree 削除。`lib/query.sh` からも呼ばれる（ランナー消失時、`<runner-exit-code>` に `died` を渡す → `error: "runner died"`）
- `runners/local <job-dir>`: v1 の agy 呼び出しを `work/` で行う。`--model "$SUBCON_MODEL" --print-timeout "$SUBCON_TIMEOUT" --json-schema "$SUBCON_SCHEMA" --settings "$SUBCON_SETTINGS"`、プロンプトは `"$(cat "$SUBCON_PROMPT_FILE")"`、出力は `<job-dir>/agy.json`

細部:
- `state` は `queued` → `running` → `finished`/`failed` の順にしか進まない
- `failed` になる条件: ランナーの終了コードが非 0 / `agy.json` が無い・JSON として読めない / `died`
- `error` の文字列: `"runner exited with <code>"` / `"agy output missing or invalid"` / `"runner died"`
- 書き込みは `lib/common.sh` の `atomic_write <path>`（stdin を一時ファイルに書いて mv）を使う
- 変更ファイルの一覧は `git -C work diff --cached --name-only <base>`（`add -A` の後）

## Acceptance
- `tests/run.sh submit`

## Notes
- 上位の作業ツリーと index は一切変更しない。変更は `<job-dir>/work` の中だけ。
- worktree はジョブのリポジトリに対して `git -C <repo> worktree add --detach <job-dir>/work <base>`。
- `bin/subcon`、`lib/common.sh`、`lib/ticket.sh`、`tests/` は編集しない。
- macOS の `/bin/bash` 3.2 で動くこと（連想配列・`mapfile`・`${x,,}` は使わない。`set -u` 下で空配列を `"${a[@]}"` と展開しない）。
