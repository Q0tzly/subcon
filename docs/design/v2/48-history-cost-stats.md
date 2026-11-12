# 48-history-cost-stats

## Goal

履歴にジョブのコストを記録し、`subcon stats` で priced / unpriced を分けて集計できるようにする（issue #2 の前段）。

現状、`history.jsonl` のジョブ行にはコストが記録されておらず（`agy.json` の `cost_usd` が捨てられている）、金額ベースの集計が一切できない。Argon レビュー Q4 の方針どおり、価格のあるジョブは合計を、無いジョブは件数を分けて出す。価格表による推定はしない。

## Files

- lib/history.sh
- lib/stats.sh
- docs/spec/files.md

## 仕様

### 履歴（lib/history.sh）

- `history_append_job` が書くジョブ行に `cost_usd` を追加する。値は `agy.json` の `cost_usd`（数値）。agy.json が無い・キーが無い場合は `null`。
- 既存の行（フィールドが無いもの）はそのまま読めること（読み側は欠けを `null` 扱い）。

### 統計（lib/stats.sh）

- stats JSON のトップレベルに `cost` オブジェクトを追加する:
  - `usd`: priced ジョブ（`cost_usd != null`）の `cost_usd` 合計。priced が 0 件なら 0。
  - `priced_jobs`: priced ジョブの件数。
  - `unpriced_jobs`: `cost_usd == null`（フィールド欠け含む）のジョブ件数。
- 集計の母集合は既存の stats と同じ（scope / since で絞った後のジョブ行）。
- `--text` 出力に Cost 行を1行足す。形は既存行に倣い、例: `Cost:          $0.75 (priced: 2, unpriced: 1)`。

### 仕様書（docs/spec/files.md）

- 履歴ジョブ行のフィールド説明に `cost_usd` を追加する（agy 出力の `cost_usd`、無ければ `null`）。

## Acceptance

- 受け入れテスト（tests/run.sh、監督が先行コミット済み）:
  - `test_history_cost_recorded`: コストを返すドライバ（fake claude、0.01）のジョブの履歴行に `cost_usd: 0.01` が入る。
  - `test_history_cost_absent_null`: コストが無いジョブ（fake agy）の履歴行は `cost_usd: null`。
  - `test_stats_cost`: priced 2件（0.5 + 0.25）と unpriced 1件を seed すると、stats の `cost.usd` = 0.75、`priced_jobs` = 2、`unpriced_jobs` = 1 になり、--text にも Cost 行が出る。
- 全テスト合格。
