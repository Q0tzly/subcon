# v2 作業票の一覧

設計: [../v2.md](../v2.md)。番号順に進める。`担当` が Flash のものだけ `subcon` で委任する。

| 票 | 内容 | 担当 | 触るファイル |
| --- | --- | --- | --- |
| 01 | テスト基盤と全票の受け入れテスト | 上位 | `tests/` |
| 02 | 振り分けと共通部品。各 lib に関数の空実装を置く | 上位 | `bin/subcon` `lib/common.sh` `lib/prompt.md` 各 lib の雛形 |
| 03 | `new` `guide` と票の検証 | Flash | `lib/ticket.sh` `templates/ticket.md` |
| 04 | `submit` とバックグラウンド実行・後処理・local ランナー | Flash | `lib/job.sh` `runners/local` |
| 05 | `wait` `show` `run` とランナー消失の検出 | Flash | `lib/query.sh` |
| 06 | `list` `diff` `apply` `discard` | Flash | `lib/manage.sh` |
| 07 | `docs/delegation.md` と README を v2 に合わせる | 上位 | `docs/` `README.md` |
| 08 | 中断からの再開 `subcon resume`（v2.1、設計は ../v2.md の「中断からの再開」） | 上位 | `lib/job.sh` `runners/local` `lib/resume-prompt.md` `tests/` |
| 09 | 使用統計の土台（呼び出し口・空実装・合格テスト） | 上位 | `lib/job.sh` `lib/manage.sh` `bin/subcon` `tests/` |
| 10 | 使用履歴の記録 | Flash | `lib/history.sh` |
| 11 | `subcon stats` | Flash | `lib/stats.sh` |
| 12 | モデル別のベンチマーク（計画は ../benchmark.md。縮小版から実施） | 未定 | 未定 |
| 13 | 履歴と stats の tokens に cache_read / thinking を足す（ベンチマーク事前準備） | Flash | `lib/history.sh` `lib/stats.sh` |
| 14 | agy の事前確認と解決（PATH に無ければ `~/.local/bin/agy`、無ければジョブを作らず終了コード 1） | Flash | `lib/common.sh` `lib/job.sh` `runners/local` |
| 15 | agy の認証方式の検出と警告（消費者ログインなら `submit` / `resume` 前に警告、API キー方式なら無言） | Flash | `lib/common.sh` `lib/job.sh` |
| 16 | container ランナー本体（設計は ../container-runner.md） | Flash | `runners/container` `runners/container-entry.sh` `container/Containerfile` |
| 17 | container の事前確認（エンジンとイメージが無ければジョブを作らず終了コード 1） | Flash | `lib/common.sh` `lib/job.sh` |
| 18 | container ジョブの作業コピーを worktree から clone に変える（コンテナ内 git 対応、イメージに safe.directory） | Flash | `lib/job.sh` `container/Containerfile` |
| 19 | CI 側の実行スクリプトとワークフローテンプレート（設計は ../ci-runner.md） | Flash | `ci/run-job.sh` `.github/workflows/subcon-job.yml` |
| 20 | CI ランナー本体（gh で dispatch・完了待ち・artifact の回収） | Flash | `runners/ci` |
| 21 | CI の事前確認（gh と認証とワークフローファイルが無ければジョブを作らず終了コード 1） | Flash | `lib/common.sh` `lib/job.sh` |

- 01・02 は合格条件と土台を決める作業なので上位がやる。`bin/subcon` は 02 で全サブコマンド分を作り、以降の票では触らない
- 03〜06 は触るファイルが重ならない。04 は 03 の `ticket_validate` を、05・06 は 04 のジョブディレクトリを前提にするので、v1（同期実行）では番号順に流す
- 07 は判断を含む文章なので上位がやる
