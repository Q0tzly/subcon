# agy の事前確認と解決（preflight）

## Goal
`agy` が PATH に無い環境でジョブが「runner exited with 127」という失敗ジョブとして死ぬ問題を直す。設計（`docs/design/v2.md` の終了コード表）どおり、agy が無ければジョブを作る前に終了コード 1 で分かるようにし、PATH に無くても `~/.local/bin/agy` にあれば使えるようにする。

## Files
- lib/common.sh
- lib/job.sh
- runners/local

## Interface
`lib/common.sh` に次の 2 関数を足す（名前と引数は変えない）。

- `agy_bin`: agy の実行ファイルのパスを stdout に出す。解決順序は (1) `command -v agy`、(2) `$HOME/.local/bin/agy` が実行可能ならそれ。どちらも無ければ何も出さず 1 を返す
- `require_agy`: `agy_bin` で解決できなければ `die "agy not found: install agy and make sure it is on PATH or at ~/.local/bin/agy"`（終了コード 1）。フォールバック（`$HOME/.local/bin/agy`）で解決したときは、そのディレクトリを `PATH` の先頭に足して export する（バックグラウンドで起動するジョブとランナーが素の `agy` で見つけられるように）

呼び出し側:

- `lib/job.sh` の `cmd_submit` と `cmd_resume` は、ジョブを 1 件も作る前に `require_agy` を呼ぶ（`cmd_run` は `cmd_submit` 経由なので変更しない）
- `lib/common.sh` の `model_name` は素の `agy` ではなく `agy_bin` で解決した実行ファイルで `models` を呼ぶ。`cmd_trailer` は最初に `require_agy` を呼ぶ（agy が無いのに「unknown model」と誤案内しないため）

`runners/local`: 先頭で、agy が PATH に無く `$HOME/.local/bin/agy` が実行可能なら、そのディレクトリを PATH の先頭に足す（事前確認を経ずにランナーが直接起動された場合の保険）。

agy を使わないコマンド（`new` `guide` `show` `list` `diff` `apply` `discard` `stats`）には事前確認を入れない。`bin/subcon` の起動時にも一律の確認を入れない。

合格テストは上位が先に書いてコミット済み（`tests/run.sh` に preflight グループを追加）。現時点で preflight グループは 4 件中 3 件落ちるのが正しい開始状態（`guide` が agy 無しで動くことを確かめる 1 件は最初から通る）。

## Acceptance
- `tests/run.sh preflight`
- `tests/run.sh`（既存のテストも全部通ること）

## Notes
- `lib/common.sh`、`lib/job.sh`、`runners/local` 以外は編集しない（特に `bin/subcon`、`tests/`、`docs/`）。
- macOS の `/bin/bash` 3.2 で動くこと（連想配列・`mapfile`・`${x,,}` は使わない。`set -u` 下で空配列を `"${a[@]}"` と展開しない）。
