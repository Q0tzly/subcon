# 51-commit-closes

## Goal

`subcon commit` が、ジョブのメタに issue 参照（票50）がある場合に、コミットメッセージへ `Closes` 行を自動で付ける（issue #8、foreman 連携の受け口の後半）。

foreman のフローは Draft PR のマージで issue を自動で閉じる。そのためにはコミット（PR に積まれる）に `Closes #N` が必要で、票と issue の対応は票50 でメタに入るようになったので、commit 時に機械的に付記できる。

## Files

- lib/manage.sh
- docs/spec/cli.md

## 仕様

### 付記ルール（cmd_commit）

- ジョブの `meta.json` に `issue: {"repo": "owner/repo", "number": N}` がある場合のみ、コミットメッセージのフッタ（トレーラ群）の最後に `Closes` 行を1行足す。無い場合は従来どおり（何も足さない）。
- 行の形は、issue の repo とカレント repo の GitHub スラッグ（lib/common.sh の `github_slug`）の一致で決める:
  - 一致する → `Closes #N`
  - 一致しない、またはスラッグが導出できない（origin が無い・GitHub でない）→ `Closes owner/repo#N`
- 重複防止: ユーザーの `-m` メッセージに既に `Closes #N` または `Closes owner/repo#N` が含まれている場合は、追加しない。

### 異なる repo の issue を指す場合の意味（仕様として明記する）

- `Closes owner/repo#N` は、そのコミットが issue のある repo のデフォルトブランチに届いた場合にだけ GitHub が自動で閉じる。それ以外の場合は参照リンクとして働く。subcon のジョブは自分の repo にコミットするので、異なる repo の issue は通常は閉じない（foreman 側で PR を作る際の手がかりになる）。

### 仕様書

- docs/spec/cli.md: `commit` の説明に `Closes` の自動付記（条件・2つの形・重複防止・異なる repo の場合の意味）を足す。

## Acceptance

- 受け入れテスト（tests/run.sh、監督が先行コミット済み）:
  - `test_commit_closes_same_repo`: origin が GitHub の repo で `--issue "#7"` のジョブをコミットすると、メッセージに `Closes #7` が入る。
  - `test_commit_closes_cross_repo`: `--issue "Q0tzly/other#12"` のジョブでは `Closes Q0tzly/other#12` が入る。
  - `test_commit_no_closes_without_issue`: issue 参照の無いジョブでは `Closes` を含まない。
  - `test_commit_closes_not_duplicated`: `-m` に既に `Closes #7` がある場合は二重に付かない。
- 全テスト合格。
