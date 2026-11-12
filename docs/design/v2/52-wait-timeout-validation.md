# 52-wait-timeout-validation

## Goal

`subcon wait --timeout` の値を検証し、期間の単位も受理する（issue #10）。

現状、`--timeout` は整数の秒数前提だが検証が無く、`20m` のような値を渡すとポーリングのたびに算術評価エラー（`((: 20m: value too great for base`）を stderr に出し続ける。実際に踏んだ。

## Files

- lib/query.sh
- docs/spec/cli.md

## 仕様

- `--timeout` の受理形式: 整数のみ（秒、従来どおり）、または単位付き `<N>s` / `<N>m` / `<N>h`（N は0以上の整数）。内部では秒に正規化する。
- それ以外の値（負数・小数・不明な単位・文字列）は、ポーリングを始める前にエラーにして終了する。
- `0` は従来どおり「無期限に待つ」。
- 算術エラーを繰り返し出す挙動が無くなること（検証で弾くため自ずと満たされる）。

## 仕様書

- docs/spec/cli.md: `wait` の `--timeout` の説明を受理形式に合わせて更新する（現状は「秒数（整数）」とだけある）。

## Acceptance

- 受け入れテスト（tests/run.sh、監督が先行コミット済み）:
  - `test_wait_timeout_units`: 実行中ジョブに `--timeout 1s` を付けると終了コード5で state が running のまま返り、`--timeout 1m` では完了まで待って終了コード0になる。
  - `test_wait_timeout_invalid`: `--timeout 5x` と `--timeout abc` が終了コード1で即エラーになる（待ちに入らない）。
- 全テスト合格。
