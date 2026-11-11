# 31-log-command

## Goal

`subcon log <id>` を新設する。委任ルール（`docs/delegation.md`）は監督役にジョブのログを読むよう指示しているが、現状は `log` ファイルを直接開くしかない。`subcon diff` と対になる読み取りコマンドとして揃える。

## Files

- bin/subcon
- lib/manage.sh

## Interface

- `lib/manage.sh` の `cmd_diff` の直後に `cmd_log` を実装する。骨格は `cmd_diff` と同型とする:
  - 引数はジョブ ID ちょうど 1 つ。無い・余分な場合は `die "job id required"`。
  - ジョブディレクトリが無ければ stderr に `subcon: unknown job id: <id>` を出して終了コード 1。
  - ジョブディレクトリの `log` ファイルが無ければ stderr に `subcon: no log for job: <id>` を出して終了コード 1。
  - あれば `log` ファイルの中身をそのまま標準出力へ出す（終了コード 0）。
- `cmd_diff` との意図的な違い: `job_result` による状態の確定は行わない。実行中のジョブでもその時点までのログが読めることがこのコマンドの価値である。
- `bin/subcon` の変更は 2 箇所のみ: usage の一覧に `       subcon log <id>` の行を `subcon diff <id>` の直後へ追加すること、dispatch の `case` に `log) cmd_log "$@" ;;` を `diff` の直後へ追加すること。他の行は変更しない。
- 仕様書（`docs/spec/cli.md`）への `log` の記載は票30が担当する。本票ではドキュメントを変更しない。

## Acceptance

- [ ] `./tests/run.sh logcmd`
- [ ] `./tests/run.sh`

## Notes

- 票30（仕様追従、ドキュメントのみ）と並行実施する。`./tests/run.sh` 全体では票30と無関係の失敗は起きない想定だが、万一自票の担当範囲（`logcmd` グループ）以外の失敗があっても、担当範囲が全て通っていれば done と報告してよい。全体の最終確認は監督側で行う。
- 引数エラーの扱いは `cmd_diff` に揃える（未知オプションの個別判定はしない。`--foo` のような引数は ID として扱われ「unknown job id」になるのが既存の流儀）。
