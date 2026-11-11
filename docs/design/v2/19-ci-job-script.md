# CI 側の実行スクリプトとワークフローテンプレート

## Goal
CI ランナー（設計は `docs/design/ci-runner.md` の「v1 の契約」）の CI 側を作る。GitHub Actions の self-hosted ランナー上で票を実行し、成果物（変更後の worktree と agy の結果）を artifact としてホスト側に戻せるようにする。

## Files
- ci/run-job.sh
- .github/workflows/subcon-job.yml

## Interface
`ci/run-job.sh`（新規、実行可能）:

- 環境変数で受け取る: `SUBCON_CI_JOB`（ジョブ ID）、`SUBCON_CI_TICKET`（対象リポジトリ内の票の相対パス）、`SUBCON_CI_BASE`（土台コミット）、`SUBCON_CI_MODEL`、`SUBCON_CI_TIMEOUT`
- 対象リポジトリのルートは `GITHUB_WORKSPACE`、無ければスクリプト自身のリポジトリルート。定数（スキーマ・プロンプト前文・agy 設定）は自リポジトリの `lib/common.sh` を source して使う
- 作業場所は `${RUNNER_TEMP:-/tmp}/subcon-<SUBCON_CI_JOB>/`。その下に `job/` と `artifact/` を作る:
  1. `job/ticket.md` に対象リポジトリの票をコピーし、`prompt.txt` = 前文 + ticket.md を作る
  2. `job/work` に対象リポジトリを clone し、`SUBCON_CI_BASE` を checkout する
  3. `SUBCON_PROMPT_FILE` / `SUBCON_MODEL` / `SUBCON_TIMEOUT` / `SUBCON_SCHEMA` / `SUBCON_SETTINGS` を export し、`SUBCON_CONVERSATION` は外して、`runners/local` を `job/` に対して実行する
  4. 成否によらず成果物をまとめる: `artifact/work.tar.gz`（`work/` をトップに含む tar）、`job/agy.json` があれば `artifact/agy.json`、`job/agy.stream` があれば `artifact/agy.stream`
  5. 最後に artifact ディレクトリのパスを stdout に出す
- 終了コード: clone や checkout など実行前の準備に失敗したら 1。`runners/local` の終了コードはそのまま返す（成果物の回収はコードによらず行う）

`.github/workflows/subcon-job.yml`（新規）:

- `workflow_dispatch` の入力: `job` / `ticket` / `base` / `model` / `timeout`（すべて必須の文字列）
- `run-name: subcon ${{ inputs.job }}`
- `runs-on: [self-hosted, subcon]`
- `permissions: contents: read`
- steps: `actions/checkout@v4`（`ref: ${{ inputs.base }}`）→ 環境変数 `SUBCON_CI_*` に入力を渡して `bash ci/run-job.sh` → `actions/upload-artifact@v4` を `if: always()` で実行し、名前 `subcon-artifact`、パス `${{ runner.temp }}/subcon-${{ inputs.job }}/artifact` をアップロードする

合格テストは上位が先に書いてコミット済み（`tests/run.sh` の cijob グループ。ワークフローを模して `ci/run-job.sh` を直接実行し、artifact の中身を検証する）。現時点で cijob グループは 2 件とも落ちるのが正しい開始状態。

## Acceptance
- `tests/run.sh cijob`
- `tests/run.sh`（既存のテストも全部通ること）

## Notes
- `ci/run-job.sh` と `.github/workflows/subcon-job.yml` 以外は編集しない（特に `bin/subcon`、`lib/`、`runners/`、`tests/`、`docs/`）。
- macOS の `/bin/bash` 3.2 で動くこと（連想配列・`mapfile`・`${x,,}` は使わない。`set -u` 下で空配列を `"${a[@]}"` と展開しない）。`set -e` のままでは失敗時に成果物をまとめられない点に注意。
- ワークフロー YAML の妥当性はテストでは検証しない（上位が目視で確認する）。
