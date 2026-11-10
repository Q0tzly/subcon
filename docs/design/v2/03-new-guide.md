# new と guide

## Goal
票の雛形を作る `subcon new` と、ルールを表示する `subcon guide` を実装する。

## Files
- lib/ticket.sh
- templates/ticket.md
- bin/subcon

## Interface
- `subcon new <feature>/<NN-name>`: リポジトリのトップからの `docs/design/<feature>/<NN-name>.md` を `templates/ticket.md` から作る。
  - 引数が `<英数字と-_>/<英数字と-_>` の形でなければ終了コード 1。
  - 既にファイルがあれば上書きせず終了コード 1。
  - 雛形の `# <title>` の行は `# <NN-name>` に置き換える。
  - stdout: `{"path": "<リポジトリのトップからの相対パス>"}` の 1 行のみ。
- `subcon guide`: `docs/delegation.md` の内容をそのまま stdout に出す。git リポジトリ外でも動く。
- `lib/ticket.sh` は `ticket_files <file>`（v1 の同名関数を移す）と `ticket_new <arg>` を定義する。
- `bin/subcon` には `new` と `guide` の振り分けだけを足す。

## Acceptance
- `tests/run.sh new guide`

## Notes
- 雛形の見出しは `docs/delegation.md` の「作業票」節と同じ（Goal / Files / Interface / Acceptance / Notes）。
- JSON の出力は `lib/common.sh` の `json_out` を使う。
- `tests/` は編集しない。
