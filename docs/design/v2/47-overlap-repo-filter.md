# 47-overlap-repo-filter

## Goal

票45 の `## Files` 重なり警告を、**現在のリポジトリのジョブだけ** を相手にするよう絞る。状態ディレクトリは全リポジトリ共有で、`## Files` はリポジトリ相対パスなので、別リポジトリで同名パス（README.md など）を持つジョブがあると無関係な警告が出てしまう。

## Files

- lib/job.sh
- docs/spec/cli.md

## 仕様

- `job_warn_overlap`（lib/job.sh）の検査対象を、相手ジョブの `meta.json` の `repo` が現在のリポジトリ（`cmd_submit` が解決した repo）と一致するものに限る。
- `meta.json` が無い・読めない・`repo` が無いジョブは対象外にする（警告を出さない側に倒す）。
- 警告の文言・出す条件（queued / running のみ、submit の成否に影響しない）は票45 のまま変えない。
- `docs/spec/cli.md`: submit の説明の「実行中の他ジョブ」を「同じリポジトリの実行中の他ジョブ」に直す。

## Acceptance

- 受け入れテスト（tests/run.sh、監督が先行コミット済み）:
  - `test_submit_overlap_no_warn_other_repo`: 別リポジトリの実行中ジョブとパスが重なっても警告が出ない。
  - `test_submit_overlap_warn_same_repo`: 同じリポジトリの実行中ジョブと重なれば警告が出る（捏造したジョブディレクトリで再現）。
  - 票45 のテスト3件が引き続き通る。
- 全テスト合格。
