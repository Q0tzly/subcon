# 63-review-docs

## Goal

レビュー機能（票58〜62 と、2026-11-15 の硬化の修正で実装済み）を、現行の仕様書・README・委任のルールに反映する。コードは変えない。設計と経緯は `docs/design/reviewer.md`（当時の記録なので書き換えない）。

## Files

- docs/spec/cli.md
- docs/spec/files.md
- docs/spec/runner.md
- docs/spec/backend.md
- README.md
- docs/delegation.md

## Interface

実装（`lib/review.sh`、`drivers/agy`、`drivers/claude`、`drivers/opencode`、`lib/manage.sh` の `cmd_commit`、`schema/review.schema.json`、`bin/subcon`）を読んで、実際の挙動のとおりに書く。設計 doc の記述と実装が食い違うときは実装が正。各ファイルの既存の書き方・見出しの流儀に合わせる。

- **docs/spec/cli.md**: `review`（ジョブ対象と `--target` / `--brief`）、`reviews`、`SUBCON_REVIEW_DRIVER` / `SUBCON_REVIEW_MODEL`、
  終了コード（0 / 1 / 2 = S1 あり / 4 = 失敗。`5` は使わない）、stdout の JSON、`commit` が最新のレビューから `Reviewed-By` を足す規則
  （`reject` では足さない、重複しない、S1 の注意は stderr）を書く
- **docs/spec/files.md**: `jobs/<id>/review-<n>.json` `.meta.json` `.stream`、`reviews/<id>/review.json` `.meta.json` `.stream`、
  `schema/review.schema.json` の形と整合規則（`approve` と S1 の関係）、meta.json のフィールド、`history.jsonl` の `type: "review"` の行
  （`stats` などの既存の集計は無視する）を書く
- **docs/spec/runner.md**: ドライバ契約に環境変数 `SUBCON_ROLE`（`implement` 既定 / `review`）を足す。review のときの各ドライバの挙動
  （agy の許可リスト、claude の `dontAsk` と `--disallowedTools`、opencode は拒否、未知の役割は終了コード 1）と、
  レビューは常にローカルで動くこと（ランナーは使わない）を書く
- **docs/spec/backend.md**: `SUBCON_ROLE=review` と `schema/review.schema.json` に従った `structured_output` を `agy.json` に書く契約を書く
- **README.md**: 使い方の節に `review` / `reviews` を 2〜3 行で足し、ドライバの節に review 役の既定（agy の Hydrogen）と
  実装役 / レビュー役が独立に選べることを書く。agy の消費者ログインの注意書きがレビューにも当てはまることを 1 文で触れる
- **docs/delegation.md**: 「監督の分担」の表の近くに、レビュー役の使い方の短い節（`subcon review <id>` を検収の前後どちらで使うか、
  指摘は鵜呑みにせず上位が仕分ける、`commit` が `Reviewed-By` を足す）を足す。既存の規則は変えない。
  「最短手順」の例に 1 行（`subcon review <id>`）を足してよい

## Acceptance

- `tests/run.sh`（全テスト合格。コードを変えていないことの確認）
- `grep -l 'SUBCON_REVIEW_DRIVER' docs/spec/cli.md README.md` が 2 ファイルとも出す
- `grep -l 'SUBCON_ROLE' docs/spec/runner.md docs/spec/backend.md` が 2 ファイルとも出す
- `grep -l 'review-<n>' docs/spec/files.md` が出す
- `git diff --stat` に `## Files` 以外が無い

## Notes

- 文書だけを変える。`lib/` `drivers/` `bin/` `tests/` `schema/` は触らない
- 既存の記述を消さない（追記と、食い違った箇所の修正だけ）
- 日本語の文書は日本語で、英語の文書は英語で書く（各ファイルの既存の言語に合わせる）
- 実装を読まずに設計 doc だけから書かない。環境変数・ファイル名・終了コード・JSON のキーは実装で確かめる
