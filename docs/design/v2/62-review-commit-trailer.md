# 62-review-commit-trailer

## Goal

`subcon commit` が、ジョブに保存済みのレビュー（票60）があれば、レビュー役のモデルを `Reviewed-By` に自動で足す。レビューが S1 を含むときは注意を出す。コミットは止めない。設計は `docs/design/reviewer.md`「commit との連携」。

## Files

- lib/manage.sh

## Interface

`cmd_commit`（既存）の、コミットメッセージを組み立てる部分だけを変える。

- 「最新のレビュー」= `review_latest <ジョブのディレクトリ>`（`lib/review.sh`、票58。`review-<n>.json` のうち `n` が数値で最大のもの）。
  結果ファイルの無い `review-<n>.meta.json`（失敗したレビュー）は数えない。最新が無ければ何も変えない（stderr にも何も出さない）
- 最新のレビューの `n` は結果ファイル名の `review-<n>.json` から取る。メタは同じ `n` の `review-<n>.meta.json`
- **trailer**: 最新のレビューの `verdict` が `reject` でなければ、`Reviewed-By: <名前> <アドレス>` を 1 行足す。`reject` のときは足さない
  - 位置: 既存の `Reviewed-By: $SUBCON_REVIEWER` の行の直後（`Closes #N` の行より前）
  - 名前: メタの `driver` と `model` から `model_name "$model" "$driver"` で引く。`driver_path` が見つからない、
    または名前が引けないときは **モデル ID をそのまま**名前にする。レビュー役のドライバの `preflight` は呼ばない
    （`require_driver` を使わない）
  - アドレス: `coauthor_email "<名前>"`（`lib/common.sh`、既存。新しい環境変数は足さない）
  - 完成した行が既存の `Reviewed-By: $SUBCON_REVIEWER` の行と同じ文字列になるなら、足さない（重複させない）
  - `--edited` の `Co-Authored-By` の扱いは変えない
- **注意（stderr）**: 最新のレビューに S1 が 1 件以上あるときは、`verdict` に関わらず stderr に 1 行
  `subcon: warning: the latest review (review-<n>) has <X> S1 finding(s)` を出す（`review_counts` の `s1`）。S1 が無ければ何も出さない。
  コミットは止めない。終了コードも変えない
- メタが読めない・結果ファイルが壊れている場合は、そのレビューを「無い」ものとして扱う（トレーラーも注意も出さず、コミットは進める）
- stdout の JSON（`{"id": …, "commit": …}`）は変えない

## Acceptance

- `tests/run.sh reviewcommit`（監督が先行コミット済みの受け入れテスト。全部通ること）
- `tests/run.sh commit`（既存の commit のテストが通ること）
- `tests/run.sh`（全テスト合格）

## Notes

- macOS の `/bin/bash` 3.2 で動かす。連想配列・`mapfile`・`${x,,}` は使わず、`set -u` 下で空配列を `"${a[@]}"` と展開しない
- `lib/review.sh` は `bin/subcon` が `manage.sh` と同じく読み込む（`review_latest` `review_counts` が使える）。`lib/review.sh` は変えない
- `model_name` は `lib/common.sh` の既存の関数。変えない
- `tests/run.sh` は触らない（監督のテスト。誤りがあると思ったら `design_questions` に書く）
