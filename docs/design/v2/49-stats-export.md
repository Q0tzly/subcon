# 49-stats-export

## Goal

将来のコントロールプレーンが読むメタデータのエクスポート形式を固定する（issue #2 の本体）。

方針: ローカルの `history.jsonl` が正で、外部に出すのはメタデータのみ。集計済みサマリ（stats）ではなくジョブ行そのものを流す形にする — 機械・repo を跨いだ集計はサマリ同士では再構成できないため、レコード形式が正。

## Files

- bin/subcon （`export` の dispatch と Usage への追加）
- lib/export.sh （新規）
- docs/spec/cli.md
- docs/spec/files.md

## 仕様

### `subcon export [--all] [--since <期間>]`

- 出力は JSON Lines（標準出力）。先頭1行がエンベロープ、続いてジョブ行。
- エンベロープ: `{"type":"export","v":1,"exported_at":"<UTC ISO8601>","scope":"repo"|"all","repo":<対象 repo の絶対パス / --all 時は null>}`。
- ジョブ行は `history.jsonl` の `type == "job"` の行をそのまま（整形しない）出す。イベント行は出さない。
- 対象範囲は stats と同じ意味論: 既定はカレントディレクトリの repo のジョブのみ、`--all` で全 repo。`--since` は `<数値>d` / `<数値>h` で、`created_at` が cutoff 以降のジョブに絞る。不正な値はエラー。
- 履歴ファイルが無い場合はエンベロープのみで正常終了する。
- 不明なオプションはエラー（他のサブコマンドと同じ作法）。

### 仕様書

- docs/spec/cli.md: サブコマンド一覧に `export` を足し、出力形式への参照を書く。
- docs/spec/files.md: エクスポート形式の節を新設する（エンベロープの形、`v: 1` の意味＝形式の版、ジョブ行は履歴のジョブ行と同一であること）。

## Acceptance

- 受け入れテスト（tests/run.sh、監督が先行コミット）:
  - `test_export_basic`: 自 repo と他 repo のジョブ行＋イベント行を seed すると、既定では自 repo のジョブ行だけがエンベロープ付きで出る（イベント行は出ない）。
  - `test_export_all`: `--all` で他 repo のジョブも出る。
  - `test_export_since`: `--since 1d` で古いジョブが落ちる。
  - `test_export_empty`: 履歴が無くてもエンベロープのみで正常終了。
  - `test_export_bad_args`: 不明なオプションと不正な `--since` がエラーになる。
- 全テスト合格。
