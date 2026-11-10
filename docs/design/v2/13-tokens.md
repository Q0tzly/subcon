# tokens に cache_read / thinking を足す

## Goal
履歴の `tokens` と `subcon stats` の集計に、agy の `usage` が返すキャッシュ読み出し（`cache_read_tokens`）と思考（`thinking_tokens`）を含める。ベンチマークでコストを計算するための事前準備（計画は `docs/design/benchmark.md`）。

## Files
- lib/history.sh
- lib/stats.sh

## Interface
`lib/history.sh` の `history_append_job` が書く `tokens`:

- agy の `usage` があるとき `{input, output, total, cache_read, thinking}` の 5 キーをこの順で出す
  - `input` / `output` / `total` は従来どおり `.input_tokens` / `.output_tokens` / `.total_tokens`
  - `cache_read` は `.cache_read_tokens`、`thinking` は `.thinking_tokens`。agy 側にそのフィールドが無ければ `null`（0 で埋めない）
- `usage` が無ければ従来どおり `tokens` 自体が `null`

`lib/stats.sh` の `cmd_stats`:

- JSON の `tokens` は `{"input": 合計, "output": 合計, "total": 合計, "cache_read": 合計, "thinking": 合計}` の 5 キーをこの順で出す。合計は `tokens` が `null` でないジョブについて、各キーが欠けているか `null` のジョブは 0 として加算する（旧形式の履歴行 — `cache_read` / `thinking` キーが無い行 — が混ざっても壊れないこと）
- `--text` の Tokens 行は `Tokens:        input <n>, output <n>, total <n>, cache_read <n>, thinking <n>` の形にする（既存の `input` / `output` / `total` の並びの後ろに足す）
- `by_model` は変更しない（`tokens_total` のみ）

合格テストは上位が先に書いてコミット済み（`tests/fake-agy` の `usage` に `cache_read_tokens: 30, thinking_tokens: 10` を追加済み、`tests/run.sh` の history / stats の期待値を更新済み）。現時点で history / stats グループは 4 件落ちるのが正しい開始状態。

## Acceptance
- `tests/run.sh history`
- `tests/run.sh stats`
- `tests/run.sh`（既存のテストも全部通ること）

## Notes
- `lib/history.sh` と `lib/stats.sh` 以外は編集しない（特に `tests/`、`docs/`）。
- macOS の `/bin/bash` 3.2 で動くこと（連想配列・`mapfile`・`${x,,}` は使わない。`set -u` 下で空配列を `"${a[@]}"` と展開しない）。集計は既存どおり jq で行う。
