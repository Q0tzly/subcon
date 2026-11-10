# list / diff / apply / discard

## Goal
発行済みジョブを一覧・確認・適用・削除するコマンドを実装する。

## Files
- lib/job.sh
- bin/subcon

## Interface
`docs/design/v2.md` のコマンド表の `list` `diff` `apply` `discard` の行のとおり。
- `apply` はパッチが当たらなければ作業ツリーを変えずに終了コード 1。
- `discard` は存在しない ID があれば何も消さずに終了コード 1。
- 未知の ID を渡されたら終了コード 1。

## Acceptance
- `tests/run.sh manage`

## Notes
- 04 で作ったジョブディレクトリの形を前提にする。04 の関数を流用してよいが、04 の挙動は変えない（`tests/run.sh jobs` も通ること）。
- `tests/` と `lib/common.sh` は編集しない。
