# `subcon reject`（差し戻し）

## Goal
検収で却下したジョブを、理由とともに差し戻すコマンドを足す。今は手作業で「票の `## Notes` に理由を追記 → 票をコミット → 再 submit」している。これを 1 コマンドにし、規約の「再委任は 1 票につき 2 回まで」も履歴から数えて強制する。中断からの再開（`resume`、会話の引き継ぎ）とは役割を分ける：reject は文脈を引き継がず、新しいジョブとして出し直す。

## Files
- bin/subcon
- lib/manage.sh
- docs/design/v2.md
- docs/delegation.md

## Interface
`lib/manage.sh` に `cmd_reject` を足し、`bin/subcon` に振り分けと usage を足す（票23の前例に従う）。

使い方: `subcon reject -m <reason> [--model M] [--runner R] <id>`（オプションは id の前。`-m` は必須。`--model` / `--runner` を省略すると元のジョブの `meta.json` の値を引き継ぐ）

動作:

1. id のジョブが無ければ終了コード 1。ジョブの `repo` が今のリポジトリのトップと一致しなければ終了コード 1（`cmd_apply` と同じ手順）
2. `-m` が無ければ（空でも）使い方の誤りとして終了コード 1
3. ジョブの結果（`job_result`）が `state: finished` でなければ終了コード 1（実行中・失敗したジョブの差し戻しはしない。失敗は `resume` の領分）
4. 再委任の上限: `history.jsonl` の、この `repo` かつこの `ticket` の確定行（`event` を持たない行）の件数を数える。3 件以上なら理由を stderr に出して終了コード 1（初回＋再委任 2 回で打ち止め）
5. 票ファイル（`meta.json` の `ticket` をリポジトリトップから解決）が無ければ終了コード 1。そのファイルに未コミットの変更があれば（`git status --porcelain -- <ticket>` が空でなければ）終了コード 1（上位の編集中の票を壊さない）
6. 票に差し戻し行 `- 差し戻し（job <id>）: <reason>` を追記する:
   - `## Notes` 節があれば、その節の末尾（次の `## ` 見出しの直前）に挿入する
   - 無ければ、ファイル末尾に `## Notes` 節を作って書く
   - 書き込みは一時ファイル＋ `mv` で置き換える（他の状態ファイルと同じ流儀）
7. 票ファイルだけを `git add -- <ticket>` してコミットする。メッセージは件名 `reject: <ticket>`、本文 `<reason>`。コミットに失敗したら終了コード 1 で止める（submit しない）
8. `history_append_event "$id" rejected` を記録する（失敗しても警告に留める。他のイベントと同じ扱い）
9. 元のジョブのランナーとモデル（または上書き指定）で `cmd_submit` を呼び、新しいジョブを起動する（`cmd_run` が `cmd_submit` の出力を捕捉する前例に従う）。stdout には `{"id": <新しい job id>, "reject_of": "<id>", "ticket": "<ticket>", "error": null}` を出す。起動に失敗したら `id: null` と理由を `error` に入れて終了コード 4（票のコミットと履歴は済んでいるので、戻さない）
10. 元のジョブは消さない（上位が `discard` する）

ドキュメント:

- `docs/design/v2.md`: コマンド表に `reject` の行を足す
- `docs/delegation.md`: 「打ち切り」節の差し戻し手順を `subcon reject` に書き換える（Notes への追記・再委任 2 回までの根拠も reject の説明として残す）

合格テストは上位が先に書いてコミット済み（`tests/run.sh` に reject グループを追加した）。開始時点では 8 件中 4 件（本体の振る舞いを見るもの）が落ちるのが正しい状態。残りは「終了コード 1 で拒否」だけを見るため未実装でも通る。

## Acceptance
- `tests/run.sh reject`
- `tests/run.sh`（既存のテストも全部通ること）

## Notes
- `bin/subcon`、`lib/manage.sh`、`docs/design/v2.md`、`docs/delegation.md` 以外は編集しない（特に `tests/`、`lib/common.sh`、`lib/job.sh`、`lib/query.sh`）。`cmd_submit` は呼び出すだけで変更しない。
- macOS の `/bin/bash` 3.2 で動くこと（連想配列・`mapfile`・`${x,,}` は使わない。`set -u` 下で空配列を `"${a[@]}"` と展開しない）。
- 履歴の件数えは `jq` で行う。`history.jsonl` が無い場合は 0 件として扱う。
- `cmd_submit` の消費者ログイン警告など stderr の出力はそのまま流してよい（stdout は JSON だけを保つ）。
