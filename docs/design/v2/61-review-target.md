# 61-review-target

## Goal

`subcon review` に、ジョブではなくリポジトリ内のファイルを読ませる形（`--target` と `--brief`）と、保存済みレビューの一覧 `subcon reviews` を足す。設計は `docs/design/reviewer.md`。ジョブ対象の実行は票60 で実装済みで、ここではその共通部分（`review_workarea` `review_snapshot` `review_conduct`）を使う。

## Files

- lib/review.sh
- bin/subcon

## Interface

### `subcon review [--driver D] [--model M] [--timeout T] --target <path>... [--brief <file>]`

`cmd_review`（既存）の引数解析を広げる。

- `--target <path>` は何度でも指定できる。1 つ以上あれば **対象モード**。`<job-id>`（位置引数）とは併用できない（併用はエラー、終了コード 1）
- `--target` なしの `--brief` はエラー（終了コード 1。メッセージに `--target` を含める）
- `--target` や `--brief` に値が無い、`--brief` のファイルが読めない、も終了コード 1
- 位置引数も `--target` も無いときは、既存どおり `job id required` で終了コード 1
- 対象の検証（`## Files` と同じ規則）。1 つでも違反があれば何も作らず終了コード 1 で、違反した対象を名指しするメッセージを stderr に出す:
  - `/` で始まらない（リポジトリのルートからの相対パス）
  - 要素に `.` や `..` を含まない
  - `*` `?` `[` を含まない
  - `HEAD` にあるファイルである（`git cat-file -e HEAD:<path>` が通り、`git cat-file -t HEAD:<path>` が `blob`）。
    未コミットの新規ファイル・ディレクトリ・存在しないパスは違反
- 対象は **カレントの repo の `HEAD`** で読む（未コミットの編集は見えない）
- 手順（`review_pick` → 検証 → 以下）:
  1. `review_workarea` で作業領域を作る
  2. `review_snapshot "$repo" HEAD "$REVIEW_TMP/clone"`（パッチ引数なし）で `HEAD` の複製とスナップショットを作る。失敗したら終了コード 4 にし、ジョブ対象と同じく失敗を保存する（下記）
  3. プロンプト `$REVIEW_TMP/driver/prompt.txt` を作る: `lib/review-prompt.md` の全文、続けて
     `--- REVIEW TARGET: files of the current directory ---` の見出しと、複製が `HEAD` のスナップショットであること・git は使えず `cat` `rg` `sed` で読むことの説明、
     `## Targets` の見出しの下に対象パスを 1 行 1 つの `- <path>` で、続けて `## Brief` の見出しの下に `--brief` のファイルの全文
     （`--brief` が無ければ `Review the target files for errors, inconsistencies, gaps and weak points.` の 1 文）
  4. `review_conduct "$snapshot" "$store" review "$review_id" "" target "$repo" "$timeout" "$extra"` を呼んで、その終了コードを返す
- `review_id` は `<YYYYmmdd-HHMMSS>-<4 桁の hex>`（UTC の現在時刻。hex は `od`/`/dev/urandom` などで作る。同じ秒に重ならないこと）
- `store` は `$(state_root)/reviews/<review_id>`。`review_conduct` が `review.json`（成功時のみ）`review.meta.json` `review.stream` を書く
- `extra`（meta に足す JSON）: `{"head": "<HEAD の SHA>", "targets": [<対象パスの配列。指定順>], "brief": <--brief のパス（指定どおりの文字列）または null>}`
- stdout の JSON と終了コード（0 / 2 / 4）は `review_conduct` が決める（ジョブ対象と同じ）。`path` は `<store>/review.json`
- 検証や引数の誤りでは `reviews` ディレクトリも作業領域も作らない（`mktemp` は検証の後）

スナップショットの準備に失敗したときの保存（ジョブ対象の `cmd_review` と同じ形）: `review_store "$store" review "$meta" ""` で、`error` に
`failed to prepare the review snapshot: <git のメッセージの先頭 300 バイト>` を入れた meta を書き、`{"id": …, "verdict": null, "error": …, "path": null}` を出して終了コード 4。meta には `target_type: "target"`、`job_id: null`、`head` `targets` `brief` も入れる。

### `subcon reviews [<job-id>]`

カレントの repo のレビューを新しい順に並べた JSON 配列（1 行、`jq -c`）を stdout に出す。レビューが無ければ `[]`。

- 対象: `$(state_root)/jobs/*/review-*.meta.json`（`.repo` がカレントの repo と一致するもの）と
  `$(state_root)/reviews/*/review.meta.json`（同じく `.repo` が一致するもの）。`review-*.meta.json` は
  `review-<数字>.meta.json` の形だけを数える
- `<job-id>` があれば、そのジョブのレビューだけ。存在しないジョブは `unknown job id: <id>` で終了コード 1。
  別の repo のジョブは `job repository (...) does not match current repository (...)` で終了コード 1
- 位置引数が 2 つ以上、未知のオプション（`--all` など）は終了コード 1
- 並び順: `created_at` の降順、同じ値なら `id` の降順
- 各要素: meta.json の全項目に次を足したもの
  - `verdict`: 結果ファイル（`review-<n>.json` / `review.json`）があればその `verdict`、なければ null
  - `s1` `s2` `s3`: 結果があれば件数（`review_counts`）、なければ null
  - `path`: 結果ファイルの絶対パス。なければ null
- 結果ファイルが壊れていて読めない場合も、その要素は `verdict` `s1` `s2` `s3` `path` を null にして出す（落ちない）

### `bin/subcon`

- usage に次を足す（`review` の行を置き換え、`reviews` を追加）:

```
       subcon review [--driver D] [--model M] [--timeout T] <job-id>
       subcon review [--driver D] [--model M] [--timeout T] --target <path>... [--brief <file>]
       subcon reviews [<job-id>]
```

- `case` に `reviews) cmd_reviews "$@" ;;` を足す

## Acceptance

- `tests/run.sh reviewtarget reviews`（監督が先行コミット済みの受け入れテスト。全部通ること）
- `tests/run.sh`（全テスト合格。既存のテストを壊していないこと）

## Notes

- macOS の `/bin/bash` 3.2 で動かす。連想配列・`mapfile`・`${x,,}` は使わず、`set -u` 下で空配列を `"${a[@]}"` と展開しない
- `lib/review.sh` の既存の関数（`review_conduct` `review_snapshot` `review_workarea` `review_store` など）は変えない。使うだけにする。
  変えないと実現できないと思ったら `design_questions` に書く
- 対象の検証と引数解析は `cmd_review` の中で、ジョブ対象の経路（既存）の挙動を変えないこと（既存の `reviewjob` グループのテストが通ること）
- `review_conduct` の第 9 引数（`extra`）は `{}` でない JSON オブジェクトを渡すこと
- `tests/run.sh` は触らない（監督のテスト。誤りがあると思ったら `design_questions` に書く）
- jq の式に `${...:-{}}` のような波括弧を含む既定値の展開を書かない（括弧の対応が崩れる）
