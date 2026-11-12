# 46-budget-cap

## Goal

単一マシン向けの簡易予算キャップを入れる（Argon レビューで「単一マシンの単純なキャップは OSS 無料分」と決定済みの分）。環境変数で月次上限を設定すると、`subcon submit` / `subcon run` が今月の実績を `history.jsonl` から集計し、上限に達していたら新しいジョブを作らずに止まる。

対象は履歴に記録されている **トークン総量** と **ジョブ件数** の2つ（履歴にコストは記録されていないため、金額キャップは対象外。金額ベースの集計は Phase C の priced / unpriced 集計と合わせて別途）。

## Files

- lib/job.sh
- lib/history.sh
- docs/spec/cli.md

## 仕様

- 設定（どちらも任意、未設定なら無制限）:
  - `SUBCON_BUDGET_TOKENS`: 今月（UTC）の終了ジョブの `tokens.total` 合計の上限。
  - `SUBCON_BUDGET_JOBS`: 今月（UTC）の終了ジョブ件数の上限。
- 集計: `lib/history.sh` に `history_month_usage` を足す。`$SUBCON_STATE/history.jsonl`（無ければ 0 扱い）から、`type == "job"` かつ `finished_at` が現在の UTC 年月（`date -u +%Y-%m`）で始まる行を集計し、`{"jobs": <件数>, "tokens": <合計>}` を stdout に出す。`tokens` が null の行は 0 として数える。
- 検査: `cmd_submit` のオプション検証後・ジョブ作成前（`cmd_run` は `cmd_submit` 経由で自動的に対象）。上限が設定されていて実績が上限以上なら、ジョブを1つも作らずにエラー終了する。メッセージには上限の種類・実績・上限値・対象月を含める。例:
  `subcon: monthly token budget reached: 120000 >= SUBCON_BUDGET_TOKENS=100000 (UTC month 2026-11)`
  `subcon: monthly job budget reached: 50 >= SUBCON_BUDGET_JOBS=50 (UTC month 2026-11)`
- 上限値が数値でない場合は設定エラーとして明示してエラー終了する（例: `subcon: invalid SUBCON_BUDGET_TOKENS: abc (must be a non-negative integer)`）。
- `resume` は対象外（既存ジョブの続きに新たな上限検査をかけない）。
- `docs/spec/cli.md`: 環境変数の表に2つを足し、submit の説明にキャップの振る舞いを書く。

## Acceptance

- 受け入れテスト（tests/run.sh、監督が先行コミット済み、新グループ `budget`）:
  - `test_budget_tokens_exceeded`: 今月の実績が上限以上なら submit が失敗し、ジョブが作られない。
  - `test_budget_tokens_under`: 上限未満なら通常どおり submit できる。
  - `test_budget_jobs_exceeded`: 件数上限に達していれば submit が失敗する。
  - `test_budget_old_month_ignored`: 先月の実績は集計に入らない。
  - `test_budget_run_blocked`: `subcon run` も同じく止まる。
  - `test_budget_invalid_value`: 数値でない上限値は設定エラーになる。
- 全テスト合格。
