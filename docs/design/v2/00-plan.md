# v2 作業票の一覧

設計: [../v2.md](../v2.md)。番号順に進める。`担当` が Flash のものだけ `subcon` で委任する。

| 票 | 内容 | 担当 | 依存 |
| --- | --- | --- | --- |
| 01 | テスト基盤（`tests/run.sh` `tests/fake-agy`）と各票の受け入れテスト | 上位 | - |
| 02 | `bin/subcon` を振り分けだけにし、`lib/common.sh` `lib/prompt.md` を切り出す | 上位 | 01 |
| 03 | `new` `guide`（`lib/ticket.sh` `templates/ticket.md`） | Flash | 02 |
| 04 | ジョブ本体: `submit` `wait` `run` `show`（`lib/job.sh` `runners/local`） | Flash | 02 |
| 05 | `list` `diff` `apply` `discard` | Flash | 04 |
| 06 | `docs/delegation.md` と README を v2 に合わせる | 上位 | 03–05 |

- 01・02 は合格条件と土台を決める作業なので上位がやる（委任の条件「作業票が書ける」を満たさない）
- 03 と 04 は独立しているので並行に委任できる（v1 は同期実行なので、この時点では順番に）
- 06 は判断を含む文章なので上位がやる
