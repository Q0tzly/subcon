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
| 23 | `subcon commit`（trailer の自動付与。レビュアー名義は `SUBCON_REVIEWER` に設定） | Flash | `bin/subcon` `lib/manage.sh` `docs/design/v2.md` `docs/delegation.md` |
| 24 | `subcon reject`（差し戻し。Notes 追記＋票コミット＋再 submit、再委任 2 回までを強制） | Flash | `bin/subcon` `lib/manage.sh` `docs/design/v2.md` `docs/delegation.md` |
| 25 | ファイル形式の版付け（`v: 1`）と history 行種別の `.type` 統一 | Flash | `lib/job.sh` `lib/history.sh` `lib/manage.sh` `docs/design/v2.md` |
| 26 | ランナー契約のモデル env を `SUBCON_MODEL` から `SUBCON_JOB_MODEL` に分離 | Flash | `lib/job.sh` `runners/local` `runners/container` `runners/container-entry.sh` `ci/run-job.sh` `docs/design/v2.md` `docs/design/container-runner.md` |
| 27 | 仕様の切り出し（`docs/spec/` を現行仕様の正本にする） | Flash | `docs/spec/cli.md` `docs/spec/files.md` `docs/spec/runner.md` `docs/spec/backend.md` `docs/design/v2.md` `README.md` |
| 28 | 入口コマンドの健全化（run の複数票、resume の ci 拒否、trailer の引数解析、wait のタイムアウト判定） | Flash | `lib/query.sh` `lib/job.sh` `lib/common.sh` |
| 29 | commit / reject の事前検証と安全化（副作用の前に検証、commit の逆適用・二重ガード、reject の上限は委任回数だけ数える） | Flash | `lib/manage.sh` |
| 30 | 仕様の追従（Argon レビュー残件: stats スキーマ・show の終了コード・委任上限・`## Files` の実仕様・ランナーの入出力と SIGTERM・env 棚卸し・プロンプト連結） | Flash | `docs/spec/cli.md` `docs/spec/files.md` `docs/spec/runner.md` `docs/spec/backend.md` |
| 31 | `subcon log <id>` の新設（ジョブの `log` ファイルをそのまま出力。実行中でも読める） | Flash | `bin/subcon` `lib/manage.sh` |
| 32 | README の公開最終形（CI ランナー節と実行ルート 2 段構えの明記、log / commit / reject の補完） | Flash | `README.md` |
| 33 | ドライバ抽出（agy 起動ブロックを `drivers/agy` へ分離、振る舞い無変更。設計は ../driver-layer.md） | Haiku（予備 Flash） | `drivers/agy` `runners/local` `runners/container-entry.sh` `container/Containerfile` `lib/job.sh` `lib/common.sh` |
| 34 | ドライバ選択と事前確認の一般化（`--driver` / `SUBCON_DRIVER`、`preflight` / `models`、resume のドライバ固定。設計は ../driver-layer.md） | Haiku（予備 Flash） | `lib/common.sh` `lib/job.sh` `bin/subcon` `tests/` |
| 35 | `drivers/claude` 本実装（claude -p の正規化、会話 ID の事前確定、フェイクでの検証。設計は ../driver-layer.md） | Haiku（予備 Flash） | `drivers/claude` `tests/` |
| 36 | ドライバの文書追従（`docs/spec/` と README に `--driver` / `SUBCON_DRIVER` / ドライバ契約を反映、usage の trailer 行） | Haiku（予備 Flash） | `docs/spec/cli.md` `docs/spec/runner.md` `docs/spec/files.md` `README.md` `bin/subcon` |
| 37 | container + claude 対応（決定 B＋ Q5 必須事項: ガード変更、`SUBCON_DRIVER` 配管、`ANTHROPIC_API_KEY` 素通し、`~/.claude` マウント、イメージ同梱。設計は ../phase6-followups.md） | Haiku（予備 Flash） | `lib/job.sh` `runners/container` `runners/container-entry.sh` `container/Containerfile` `docs/spec/cli.md` `docs/spec/runner.md` |
| 38 | ci + claude 対応（決定 C: `SUBCON_CI_DRIVER` の配管、認証は setup-token 主＋ API キー予備で `~/.config/subcon/claude-env` から読み込み。設計は ../phase6-followups.md） | Haiku（予備 Flash） | `lib/job.sh` `runners/ci` `.github/workflows/subcon-job.yml` `ci/run-job.sh` `docs/spec/cli.md` `docs/spec/runner.md` |
| 39 | `drivers/opencode` 本実装（改訂後の決定 A: プロンプト指示＋3段階抽出・検証、失敗時は報告なし完了。起動ウォッチドッグ、usage 写像、`model_name` フォールバック、`exit_code_for` の null→2 追従。設計は ../phase6-followups.md） | Haiku（予備 Flash） | `drivers/opencode` `lib/common.sh` `lib/query.sh` `docs/spec/cli.md` `README.md` |
| 40 | 履歴・統計への `driver` 記録（`history.jsonl` に `driver`、`stats` に `by_driver`。Q10）と、会話 ID 保証の 2 段階の仕様明記（Q2） | Haiku（予備 Flash） | `lib/history.sh` `lib/stats.sh` `docs/spec/files.md` `docs/spec/backend.md` `docs/spec/runner.md` |
| 42 | `drivers/claude` に agy と同じ `$HOME/.local/bin` フォールバック（票41 の CI 実機確認で発見した PATH 解決の非対称の解消） | Haiku（予備 Flash） | `drivers/claude` `docs/spec/runner.md` |
| 43 | `subcon trailer` の既定を直近ジョブの driver / model にする（省略時に agy 固定だった帰属のズレ解消） | Haiku（予備 Flash） | `lib/common.sh` `docs/spec/cli.md` |
| 44 | `drivers/opencode` に `$HOME/.opencode/bin` フォールバック（票42 と同種の PATH 解決） | Haiku（予備 Flash） | `drivers/opencode` `docs/spec/runner.md` |
| 45 | 実行中ジョブとの `## Files` 重なり警告（submit / run、ブロックしない） | Haiku（予備 Flash） | `lib/job.sh` `docs/spec/cli.md` |
| 46 | 単一マシン向け簡易予算キャップ（`SUBCON_BUDGET_TOKENS` / `SUBCON_BUDGET_JOBS`、月次・履歴集計） | Haiku（予備 Flash） | `lib/job.sh` `lib/history.sh` `docs/spec/cli.md` |
| 47 | 重なり警告のリポジトリ絞り込み（票45 の追補: 状態ディレクトリは全 repo 共有で相対パス比較が偽陽性を出すため） | Haiku（予備 Flash） | `lib/job.sh` `docs/spec/cli.md` |
| 48 | 履歴への `cost_usd` 記録と stats の priced / unpriced 集計（issue #2 の前段） | Haiku（予備 Flash） | `lib/history.sh` `lib/stats.sh` `docs/spec/files.md` |
| 49 | `subcon export` の新設とメタデータ形式の固定（issue #2 の本体） | Haiku（予備 Flash） | `bin/subcon` `lib/export.sh` `docs/spec/cli.md` `docs/spec/files.md` |
| 50 | 票メタへの issue 参照（`--issue`、issue #7・foreman 受け口の前半） | Haiku（予備 Flash） | `lib/common.sh` `lib/job.sh` `lib/query.sh` `docs/spec/cli.md` `docs/spec/files.md` |
| 51 | `subcon commit` での `Closes #N` 自動付記（issue #8・foreman 受け口の後半） | Haiku（予備 Flash） | （票50 の着地後に確定） |

- 01・02 は合格条件と土台を決める作業なので上位がやる。`bin/subcon` は 02 で全サブコマンド分を作り、以降の票では触らない
- 03〜06 は触るファイルが重ならない。04 は 03 の `ticket_validate` を、05・06 は 04 のジョブディレクトリを前提にするので、v1（同期実行）では番号順に流す
- 07 は判断を含む文章なので上位がやる
