# new / guide と票の検証

## Goal
票の雛形を作る `subcon new`、ルールを表示する `subcon guide`、`submit` が使う票の検証を実装する。

## Files
- lib/ticket.sh
- templates/ticket.md

## Interface
`lib/ticket.sh` に次の関数を実装する（02 で空実装が置いてある。名前と引数は変えない）。

- `cmd_new <arg>`
  - `<arg>` が正規表現 `^[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$` に一致しなければ stderr にエラー、終了コード 1
  - 作るファイル: リポジトリのトップからの `docs/design/<arg>.md`。親ディレクトリは作る
  - 既にファイルがあれば上書きせず終了コード 1
  - 内容は `templates/ticket.md` の 1 行目 `# <title>` を `# <arg の / より後>` に置き換えたもの
  - stdout: `json_out` で `{"path": "docs/design/<arg>.md"}` を 1 行
- `cmd_guide`: `$SUBCON_ROOT/docs/delegation.md` をそのまま stdout に出す。git リポジトリ外でも動く
- `ticket_files <file>`: `## Files` 節の `- path`（バッククォート可）を 1 行 1 件で出す。v1 の同名関数と同じ動作
- `ticket_validate <repo-relative-path>`: カレントはリポジトリのトップ。`docs/design/v2.md` の「票の検証」節を満たせば 0、満たさなければ理由を stderr に 1 行出して 1
  - 票が `HEAD` に無い、または `git diff --quiet HEAD -- <path>` が失敗 → 1
  - `## Files` が空 → 1
  - パスが `/` で始まる、要素に `.` か `..` がある、`*` `?` `[` を含む → 1

`templates/ticket.md` は `docs/delegation.md` の「作業票」節のコードブロックと同じ見出し（Goal / Files / Interface / Acceptance / Notes）で、1 行目は `# <title>`。

## Acceptance
- `tests/run.sh ticket`

## Notes
- JSON の出力は `lib/common.sh` の `json_out`、エラーは `die`（終了コード 1）を使う。
- `bin/subcon`、`lib/common.sh`、`tests/` は編集しない。
- macOS の `/bin/bash` 3.2 で動くこと（連想配列・`mapfile`・`${x,,}` は使わない。`set -u` 下で空配列を `"${a[@]}"` と展開しない）。
