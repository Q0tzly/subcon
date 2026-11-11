# CI ランナーの事前確認

## Goal
`--runner ci` のジョブは、gh が無い・未認証・ワークフローファイルが無いと失敗ジョブとして死ぬ。票17（container の事前確認）と同じ形で、ジョブ作成前に3点を確かめ、欠けていれば終了コード 1 で理由を出して止める。

## Files
- lib/common.sh
- lib/job.sh

## Interface
`lib/common.sh` に `require_ci` を足す（引数は対象リポジトリのパス 1 つ）:

- `gh` が解決できなければ `die "ci runner requires gh: install the GitHub CLI"`
- `gh auth status` が失敗したら `die "gh is not authenticated: run gh auth login"`
- `<repo>/.github/workflows/subcon-job.yml` が無ければ `die "workflow not found: .github/workflows/subcon-job.yml (add the subcon-job workflow to this repository)"`

呼び出し側（`lib/job.sh`）:

- `cmd_submit` は、使うランナーが決まり対象リポジトリが確定した後・ジョブを 1 件も作る前に、ランナーが `ci` のときだけ `require_ci "$repo"` を呼ぶ。他ランナーでは呼ばない（`cmd_run` は `cmd_submit` 経由なので変更しない）
- `cmd_resume` は、元のジョブのランナーが `ci` のときだけ、新しいジョブを作る前に `require_ci` を呼ぶ（対象リポジトリは元のジョブのもの）

合格テストは上位が先に書いてコミット済み（`tests/run.sh` に cipre グループを追加し、`tests/fake-gh` に `auth status` の模倣を足した）。現時点で cipre グループは 4 件中 3 件落ちるのが正しい開始状態（事前確認がまだ無いため）。

## Acceptance
- `tests/run.sh cipre`
- `tests/run.sh`（既存のテストも全部通ること）

## Notes
- `lib/common.sh` と `lib/job.sh` 以外は編集しない（特に `bin/subcon`、`tests/`、`docs/`、`runners/`、`ci/`、`.github/`）。
- macOS の `/bin/bash` 3.2 で動くこと（連想配列・`mapfile`・`${x,,}` は使わない。`set -u` 下で空配列を `"${a[@]}"` と展開しない）。
- `gh auth status` の出力は捨ててよく、成否だけを見る。
