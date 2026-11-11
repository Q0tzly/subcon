# 38-ci-claude

## Goal

ci ランナーで `claude` ドライバを使えるようにする（フェーズ6 後続、設計は ../phase6-followups.md の決定 C）。認証は setup-token を第一とし、`ANTHROPIC_API_KEY` を予備とする。鍵はランナーマシン上にだけ置き、GitHub Secrets や制御面には渡さない。

## Files

- lib/job.sh
- runners/ci
- .github/workflows/subcon-job.yml
- ci/run-job.sh
- docs/spec/cli.md
- docs/spec/runner.md

## Interface

### lib/job.sh — ci ガードの緩和

- 現行の ci ガード（`ci` かつ `driver != agy` で `the ci runner supports the agy driver only`）を置き換える: `ci` かつ `driver` が `agy` でも `claude` でもない場合に `die "the ci runner supports the agy and claude drivers only"`。
- container 側のガード（票37）は無変更。ホスト側では claude の認証情報の有無を確認しない（認証はランナーマシン側にしか無いため。認証不備は CI 側で失敗として現れる）。

### runners/ci — ドライバの伝播

- `meta.json` からドライバを読む（`.driver // "agy"`。票37 以前のジョブ互換）。
- `gh workflow run` の入力に `driver` を追加する。**ただし後方互換のため、`driver` が `agy` でない場合のみ `-f "driver=$driver"` を渡す**（5 入力版の旧ワークフローファイルでも agy ジョブが従来どおり動くように）。

### .github/workflows/subcon-job.yml — driver 入力の追加

- `workflow_dispatch` の入力に `driver` を追加する（`required: false`、`default: 'agy'`、`type: string`）。
- 実行ステップの env に `SUBCON_CI_DRIVER: ${{ inputs.driver }}` を追加する。

### ci/run-job.sh — ドライバ適用と claude 認証の読み込み

- ドライバは `SUBCON_CI_DRIVER`（未設定・空なら `agy`）で決め、`runners/local` の実行前に `SUBCON_DRIVER` として export する。
- `driver == claude` の場合のみ、認証を次の順で用意する:
  1. `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY` のどちらかが環境に非空で設定されていれば、そのまま使う。
  2. どちらも無く、`$HOME/.config/subcon/claude-env` が読めるファイルとして存在すれば、それを source する（`set -a` で囲み、素の `KEY=value` 行でも export されるようにする）。
  3. それでもどちらも無ければ、clone や実行に進まず終了コード 1 で失敗する。stderr の文面には `~/.config/subcon/claude-env` への言及と setup-token の失効（1 年）への注意を含める。例: `ci/run-job.sh: no claude credentials: set CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY (on a self-hosted runner, place them in ~/.config/subcon/claude-env; a setup-token expires after 1 year - check ~/.config/subcon/claude-token-expires)`。
- `driver == agy` の場合は認証まわりに一切触らない（現行どおり）。

### docs/spec/cli.md

- `--driver D` の説明のうち ci についての部分を現行仕様に合わせる: `ci` ランナーも `agy` と `claude` に対応する。`claude` の認証はランナーマシン側で setup-token（`CLAUDE_CODE_OAUTH_TOKEN`）または `ANTHROPIC_API_KEY` を用意する。

### docs/spec/runner.md（ci ランナー節と環境変数表）

- ワークフロー契約の入力を 6 つに更新する（`job` / `ticket` / `base` / `model` / `timeout` / `driver`）。あわせて注記する: `driver` は `agy` でない場合のみ dispatch 時に渡され、5 入力の旧ワークフローでも `agy` ジョブは従来どおり動く。`claude` ジョブには 6 入力版のワークフローが必要。
- 環境変数表（内部受け渡し）に `SUBCON_CI_DRIVER` の行を追加する（`ci/run-job.sh` が受け取り `SUBCON_DRIVER` としてランナーへ渡す）。
- claude 認証の読み込み順（環境変数 → `~/.config/subcon/claude-env` → 失敗）を ci 節に明記する。鍵を GitHub Secrets に置かない方針も書く。

## Acceptance

- [ ] `./tests/run.sh cijob`
- [ ] `./tests/run.sh cirunner`
- [ ] `./tests/run.sh driver`
- [ ] `./tests/run.sh`
- [ ] `grep -q 'SUBCON_CI_DRIVER' .github/workflows/subcon-job.yml`

## Notes

- 本票の実装役は Haiku（subcon シム経由。尽きたら Flash）。
- テストは監督側が用意済み（`tests/run.sh` の cijob / cirunner / driver グループと `tests/fake-gh` の driver 入力の受け渡し）。テストファイルとフィクスチャは変更しないこと。既存テスト `test_driver_ci_guard` の期待文は本票の新文面に合わせて監督側で更新済み。
- 実トークンの発行（`claude setup-token`）とランナーマシンへの配置はユーザーが行い、実機確認は監督側が実施する。本票の受け入れには含めない（テストはダミー値で完結する）。
- `drivers/claude` は変更しない。preflight への env 分岐も追加しない（票37 の Notes と同じ実機確認に基づく）。
