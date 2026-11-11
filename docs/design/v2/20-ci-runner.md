# CI ランナー本体

## Goal
CI ランナー（設計は `docs/design/ci-runner.md` の「v1 の契約」）のホスト側を作る。`--runner ci` のジョブで GitHub Actions のワークフロー（票19）を起動し、完了を待って artifact を回収し、ジョブディレクトリに戻す。

## Files
- runners/ci

## Interface
`runners/ci`（新規、実行可能）。引数は他のランナーと同じくジョブディレクトリ。`meta.json` から `repo` / `ticket` / `base` / `model` / `timeout` を読む。ジョブ ID はジョブディレクトリの basename。

- `gh` が PATH に無ければ、stderr にその旨を出して 1 で終了する
- dispatch: `repo` をカレントディレクトリにして `gh workflow run subcon-job.yml -f job=<id> -f ticket=<ticket> -f base=<base> -f model=<model> -f timeout=<timeout>`。失敗したら 1 で終了する
- 完了待ち: まず即座に確認し、以降は `${SUBCON_CI_POLL:-5}` 秒ごとに `gh run list --workflow subcon-job.yml --limit 20 --json databaseId,displayTitle,status,conclusion` を実行し、`displayTitle` が `subcon <id>` の run を探す。`status` が `completed` になったら次へ。締め切りは `timeout` を秒に直した値 ＋ 120 秒（`timeout` の解釈: `30m` は分、末尾 `s` は秒、裸の数字は秒）。締め切りを超えたら、run が特定できていれば `gh run cancel <databaseId>` を試みて 1 で終了する
- 回収: 一時ディレクトリに `gh run download <databaseId> -n subcon-artifact -D <tmp>` する。`work.tar.gz` があれば、ジョブの `work/` を消してからジョブディレクトリに展開して戻す。`agy.json` / `agy.stream` があればジョブディレクトリにコピーする。download に失敗したら 1 で終了する
- 終了コード: run の `conclusion` が `success` なら 0、それ以外は 1（回収は結論によらず試みる）
- INT / TERM / HUP を受けたら、run の cancel を試みて 143 で終了する（他のランナーの trap と同じ形）

合格テストは上位が先に書いてコミット済み（`tests/fake-gh` と `tests/run.sh` の cirunner グループ。fake-gh は dispatch の模倣として本物の `ci/run-job.sh` を実行し artifact を作る）。現時点で cirunner グループは 3 件とも落ちるのが正しい開始状態。

## Acceptance
- `tests/run.sh cirunner`
- `tests/run.sh`（既存のテストも全部通ること）

## Notes
- `runners/ci` 以外は編集しない（特に `bin/subcon`、`lib/`、`tests/`、`docs/`、`ci/`、`.github/`）。
- macOS の `/bin/bash` 3.2 で動くこと（連想配列・`mapfile`・`${x,,}` は使わない。`set -u` 下で空配列を `"${a[@]}"` と展開しない）。
- `gh` の呼び出しは Interface に書いた形に合わせる（テストの模倣が前提にしている）。
