# 55-agy-read-scope

## Goal

agy ドライバの権限設定に `read_file` の許可を足し、ワークスペース外の読み取りでランが無言死するのを直す（issue #17）。

現状、`drivers/agy` が渡す `--settings` の allow は `command(*)` のみ。agy の権限モデルではワークスペース外のファイル読み取りは既定で確認（ask）扱いになり、ヘッドレス実行では自動 deny されてラン全体が結果なしで終わる。兄弟 repo のソースを参照したいジョブ（grus2llvm で実例5回）が踏んだ。

## Files

- drivers/agy

## 仕様

- settings を組み立てる際に、allow へ次の `read_file` ルールを追加する（パスは絶対パス。ディレクトリを指定すると配下全体が対象になる、という agy の規則に従う）:
  - `read_file(<ジョブ dir>)`: ジョブディレクトリそのもの。
  - repo の親ディレクトリ: ジョブの `meta.json` の `repo` の親。ただし親が `$HOME` 自体または `/` の場合は親ではなく repo 自体（`read_file(<repo>)`）にする（ホーム全体を読みに開けないためのガード）。
- 既存の `command(*)` の allow と deny リストは変更しない。`write_file` は広げない（ワークスペース外への書き込みは従来どおり不可のまま）。
- repo が meta.json から読めない場合は、ジョブ dir のルールだけで従来どおり動くこと（落とさない）。

## Acceptance

- 受け入れテスト（tests/run.sh、監督が先行コミット済み）:
  - `test_driver_agy_read_scope`: 通常ジョブで fake-agy に渡った `--settings` の中に、`read_file(<repo の親 dir>)` と `read_file(<ジョブ dir>)` が含まれる。
- 全テスト合格。
