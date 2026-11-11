# container ジョブの作業コピーを worktree から clone に変える

## Goal
container ジョブの `work/` は git worktree のため、`.git` ファイルが指すホスト側 gitdir がコンテナ内から見えず、コンテナ内の git が一切使えない（2026-11-11 に実機検証済み）。container ジョブでは worktree の代わりにローカル clone を作り、`work/` の中に実体の `.git` を持たせる。本体の `.git` はコンテナに一切マウントしない。あわせて、macOS の virtiofs ではマウント内ファイルが root 所有に見えて git の dubious ownership に触れるため、イメージ側で `/work` のみ `safe.directory` に入れる。

## Files
- lib/job.sh
- container/Containerfile

## Interface
- `lib/job.sh` の `job_create` は、ランナーが `container` のときだけ、現在の `git worktree add --detach <work> <base>` の代わりに次を行う:
  1. `git clone -q <repo> <job_path>/work`
  2. `git -C <job_path>/work checkout -q <base>`（base に detached で合わせる。worktree の現行動作と同じ）
  どちらかが失敗したら、従来の worktree 作成失敗と同じ扱いでジョブ作成エラーにする。`local` 等の他ランナーは従来どおり worktree。
- 後処理・終了時の掃除・resume のパッチ適用は変更しない（clone は通常のディレクトリで、既存の `rm -rf` フォールバックと `git -C work` 系コマンドがそのまま動く）。
- `container/Containerfile` は、`USER runner` の後に runner ユーザーのグローバル設定として `git config --global --add safe.directory /work` を実行する行を足す。対象は `/work` のみ（`*` は使わない）。

合格テストは上位が先に書いてコミット済み（`tests/fake-agy` に layout モード、`tests/run.sh` の container グループに `test_container_clone_layout` を追加）。現時点でこのテストは 1 件落ちるのが正しい開始状態。

## Acceptance
- `tests/run.sh container`
- `tests/run.sh`（既存のテストも全部通ること）

## Notes
- `lib/job.sh` と `container/Containerfile` 以外は編集しない（特に `bin/subcon`、`tests/`、`docs/`、`runners/`、`lib/common.sh`）。
- macOS の `/bin/bash` 3.2 で動くこと（連想配列・`mapfile`・`${x,,}` は使わない。`set -u` 下で空配列を `"${a[@]}"` と展開しない）。
- clone の origin がホスト側パスを指すのは構わない（コンテナ内からの fetch は想定しない）。
