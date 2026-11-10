# container ランナーの事前確認

## Goal
`--runner container` のジョブは、エンジンやイメージが無いと「runner exited with 1」の失敗ジョブとして死ぬ。票14（agy の事前確認）と同じ形で、エンジンとイメージの有無をジョブ作成前に確認し、無ければ終了コード 1 で理由を出して止める。

## Files
- lib/common.sh
- lib/job.sh

## Interface
`lib/common.sh` に次の 2 関数を足す（名前と引数は変えない）。

- `container_engine`: エンジンの実行ファイルを stdout に出す。解決順序は `runners/container` と同じ: (1) `SUBCON_CONTAINER_ENGINE` が設定されていればその値、(2) `command -v docker`、(3) `command -v podman`。どれも無ければ何も出さず 1 を返す
- `require_container`: `container_engine` で解決できなければ `die "container engine not found: install docker or podman"`. 解決できたら `<engine> image inspect <image>` を実行し、失敗したら `die "container image not found: <image> (build it from container/Containerfile)"`. `<image>` は `SUBCON_CONTAINER_IMAGE`、既定 `subcon-runner:latest`（`runners/container` と同じ既定値）

呼び出し側:

- `lib/job.sh` の `cmd_submit` は、引数を解釈して使うランナーが決まった後・ジョブを 1 件も作る前に、ランナーが `container` のときだけ `require_container` を呼ぶ。`local` 等では呼ばない（`cmd_run` は `cmd_submit` 経由なので変更しない）
- `cmd_resume` は、元のジョブのランナー（`meta.json` の `runner`）が `container` のときだけ、新しいジョブを作る前に `require_container` を呼ぶ

合格テストは上位が先に書いてコミット済み（`tests/run.sh` に containerpre グループを追加し、`tests/fake-engine` に `image inspect` の模倣を足した）。現時点で containerpre グループは 4 件中 2 件落ちるのが正しい開始状態（事前確認がまだ無いため）。

## Acceptance
- `tests/run.sh containerpre`
- `tests/run.sh`（既存のテストも全部通ること）

## Notes
- `lib/common.sh` と `lib/job.sh` 以外は編集しない（特に `bin/subcon`、`tests/`、`docs/`、`runners/`）。
- macOS の `/bin/bash` 3.2 で動くこと（連想配列・`mapfile`・`${x,,}` は使わない。`set -u` 下で空配列を `"${a[@]}"` と展開しない）。
- `image inspect` の出力は捨ててよく、成否だけを見る。
