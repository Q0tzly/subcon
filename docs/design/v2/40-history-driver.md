# 40-history-driver

## Goal

履歴と統計にドライバを記録・集計できるようにする（フェーズ6 後続、Argon レビュー Q10）。既定ドライバの切替判断（一次検収通過率などの比較）が `history.jsonl` から測れるようにするのが目的。あわせて会話 ID 保証の 2 段階を仕様に明記する（Q2）。

## Files

- lib/history.sh
- lib/stats.sh
- docs/spec/files.md
- docs/spec/backend.md
- docs/spec/runner.md

## Interface

### lib/history.sh — finalize 行への driver 記録

- `history_append_job` が書く finalize 行に `driver` を追加する。値は `meta.json` の `driver`（ドライバ記録が無い旧ジョブは `"agy"`）。並びは `runner` の直後。

### lib/stats.sh — by_driver 集計

- 統計 JSON に `by_driver` を追加する。構造は `by_model` と同一（`jobs` / `success` / `applied` / `tokens_total`）で、キーはドライバ名。集計キーは履歴行の `driver`（**フィールドが無い旧行は `"agy"` として数える**）。
- テキスト表示にも `Model breakdown:` と同形式の `Driver breakdown:` 節を追加する（見出し行は `DRIVER`）。

### docs/spec/files.md — finalize 行の仕様追従

- finalize 行の例に `"driver": "agy"` を追加する（`runner` の直後）。
- フィールド説明に `driver` を加える: 実行したドライバ名（ドライバ記録の無い旧ジョブは `"agy"` として記録される）。

### docs/spec/backend.md / docs/spec/runner.md — 会話 ID 保証の 2 段階（Q2）

会話 ID（`conversation_id`）の保証レベルがドライバで異なることを両文書に明記する:

- **事前確定**: `claude`。実行前に ID を確定してドライバへ渡すため、実行が途中で kill されても resume できる。
- **ベストエフォート回収**: `agy` / `opencode`。ストリームの最初のイベントから ID を回収する。最初のイベントが出る前に kill された場合は ID が残らず（`conversation` は `null`）、resume はできない。その場合は作業が始まっていないため、同じ票を再 submit してよい。

置き場所: backend.md は「会話の継続（`resume`）」節、runner.md は local ランナー節の会話 ID 回収の記述の近く。

## Acceptance

- [ ] `./tests/run.sh history`
- [ ] `./tests/run.sh stats`
- [ ] `./tests/run.sh`

## Notes

- 本票の実装役は Haiku（subcon シム経由。尽きたら Flash）。
- テストは監督側が用意済み（`tests/run.sh` の history / stats グループ。`hjob` ヘルパーに任意の第 11 引数 `driver` を追加済み）。テストファイルは変更しないこと。
- 形式の版（`v`）は上げない。`driver` は追加フィールドであり、読み手は未知フィールドを無視する既存の互換方針に従う（meta.json の `driver` 追加時と同じ扱い）。
