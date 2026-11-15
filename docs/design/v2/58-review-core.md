# 58-review-core

## Goal

レビュー機能（設計は `docs/design/reviewer.md`）の土台を作る。出力のスキーマ、レビュー役に渡す指示文、結果の検証・集計・採番の関数、`history.jsonl` への追記関数だけで、`subcon review` コマンドや実行処理は作らない（票60 以降）。

## Files

- schema/review.schema.json
- lib/review-prompt.md
- lib/review.sh
- lib/history.sh
- bin/subcon

## Interface

### schema/review.schema.json

JSON Schema（`schema/result.schema.json` と同じ書き方）。トップレベルは `additionalProperties: false`、`required` は `verdict` `summary` `findings` `unverified`。

- `verdict`: 文字列、`enum: ["approve","changes","reject"]`
- `summary`: 文字列
- `findings`: 配列。要素は `additionalProperties: false`、全項目 required:
  `severity`（`enum: ["S1","S2","S3"]`）、`file`（文字列）、`line`（整数、`minimum: 0`）、
  `summary` `failure_scenario` `fix`（文字列）
- `unverified`: 文字列の配列

### lib/review-prompt.md

レビュー役への指示文（英語）。対象の中身は含めない（票60 が後ろに足す）。次を必ず含める:

- 読み取り専用であること。`Do not modify any file.` の一文を含める
- S1（誤り・保証の穴）／ S2（弱点）／ S3（軽微）の定義
- 読めなかった・確かめられなかったものは `unverified` に書くこと。空にするのは全部確かめたときだけ
- 指摘が無ければ `findings` を空にして `verdict` を `approve` にすること。S1 が 1 件でもあれば `approve` にしないこと
- 各指摘に `file` `line`（行が特定できないときは 0）`summary` `failure_scenario` `fix` を書くこと

### lib/review.sh

次の関数だけを定義する（`bin/subcon` から `source` される。単独で実行されない）。`set -u` の下で動くこと。

- `review_validate <file>`: レビュー結果の JSON を検証する。通れば終了コード 0。
  失敗時は終了コード 1 で、理由を stderr に 1 行出す。検証は次の順:
  1. ファイルが存在し JSON として読める
  2. スキーマの形に合う（必須項目・型・enum・`line >= 0`・余分な項目なし）。`jq` で書く（外部のスキーマ検証器は使わない）
  3. 整合: `findings` が空なら `verdict` は `approve`、S1 が 1 件でもあれば `verdict` は `approve` ではない。
     破れていれば stderr に `inconsistent verdict` を含む行を出す
- `review_counts <file>`: `{"s1":n,"s2":n,"s3":n}` を 1 行（`jq -c` 形式）で stdout に出す。検証済みの結果を前提にする
- `review_next_n <dir>`: `<dir>/review-<n>.meta.json` の `n` の数値最大 + 1 を stdout に出す。1 つも無ければ `1`
- `review_latest <dir>`: `<dir>/review-<n>.json`（`.meta.json` や `.stream` は含まない）のうち `n` が数値で最大のものの
  パスを stdout に出す。1 つも無ければ何も出さず終了コード 1。文字列の並びで比べない（`review-10` は `review-2` より新しい）

### lib/history.sh

- `history_append_review <meta-file> <review-file>`: `history.jsonl` に 1 行追記する（既存の `_history_append` を使う）。
  `meta-file` は次のキーを持つ JSON: `v` `id` `job_id`（無ければ null）`target_type`（`job` または `target`）
  `repo` `created_at` `driver` `model` `duration_seconds`（null 可）`cost_usd`（null 可）`usage`（null 可。
  あれば `input_tokens` `output_tokens` `total_tokens` `cache_read_tokens` `thinking_tokens`）。
  `review-file` は検証済みの結果。追記する行:

```json
{"v":1,"type":"review","id":…,"target_type":…,"job_id":…,"repo":…,"created_at":…,"driver":…,"model":…,
 "verdict":…,"s1":n,"s2":n,"s3":n,"duration_s":…,"cost_usd":…,
 "tokens":{"input":…,"output":…,"total":…,"cache_read":…,"thinking":…}}
```

  `job_id` がキーごと無い・null の場合は `job_id: null`。`usage` が null なら `tokens: null`。
  `duration_s` は `duration_seconds` の値。件数は `review_counts` と同じ数え方
  （`history_append_review` は `lib/review.sh` の関数に依存してよい。どちらも `bin/subcon` で読み込まれる）。
  成功で 0、失敗で 1。
- 既存の関数・既存の行の形は変えない。`stats` `export` `history_month_usage` はレビューの行を無視すること
  （既存の `.type == "job"` の絞り込みで既にそうなっている。変更は不要で、壊さないこと）

### bin/subcon

`for f in common ticket job query manage history stats export; do` の `export` の後ろに `review` を足す。他は変えない。

## Acceptance

- `tests/run.sh review`（監督が先行コミット済みの受け入れテスト。全 11 本が通ること）
- `tests/run.sh`（全テスト合格。既存のテストを壊していないこと）

## Notes

- macOS の `/bin/bash` 3.2 で動かす。連想配列・`mapfile`・`${x,,}` は使わず、`set -u` 下で空配列を `"${a[@]}"` と展開しない
- `jq` のみ使う（`ajv` などは使わない）
- `lib/review.sh` に `review_validate` 以外の検証や、レビュー実行のコードを入れない（票60・61 の範囲）
- テストの `rv` ヘルパーは `common ticket job query manage history stats export review` を順に `source` する。
  `review.sh` はトップレベルで関数定義以外を実行しないこと
- `tests/run.sh` は触らない（監督のテスト。誤りがあると思ったら `design_questions` に書く）
