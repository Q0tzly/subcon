# container ランナー本体

## Goal
`--runner container` で、ジョブの `work/` をマウントした使い捨てコンテナの中で agy を実行できるようにする。設計は `docs/design/container-runner.md`。ランナー契約（引数はジョブディレクトリ、`agy.json` の責務、終了コード）は local ランナーと同じ。

## Files
- runners/container（新規）
- runners/container-entry.sh（新規）
- container/Containerfile（新規）

## Interface

### runners/container（ホスト側）

- エンジン解決: `SUBCON_CONTAINER_ENGINE` があればそれ、無ければ `command -v docker` → `command -v podman` の順。どちらも無ければ stderr にメッセージを出して 1 で終わる
- ジョブディレクトリを絶対パス化する（local と同じ）。`$SUBCON_SCHEMA` を `$job_dir/schema.json` にコピーする
- 認証用ディレクトリ: `$HOME/.gemini` が無ければ作る（マウント元が無いとエンジンが root 所有で作ってしまうため）
- コンテナ名は `subcon-<ジョブID>`（ジョブディレクトリの basename）。イメージは `SUBCON_CONTAINER_IMAGE`、既定 `subcon-runner:latest`
- 起動コマンドは次の形に固定する（テストが fake engine でこの形を検証する）:

```
<engine> run --rm --name <name> \
  --workdir /work \
  --user <id -u>:<id -g> \
  -v <job_dir>/work:/work -v <job_dir>:/job -v $HOME/.gemini:/home/runner/.gemini \
  -e HOME=/home/runner -e SUBCON_JOB_DIR=/job \
  -e SUBCON_PROMPT_FILE=/job/prompt.txt -e SUBCON_SCHEMA=/job/schema.json \
  -e SUBCON_SETTINGS -e SUBCON_MODEL -e SUBCON_TIMEOUT \
  [-e SUBCON_CONVERSATION] [-e GEMINI_API_KEY] \
  <image> /usr/local/bin/subcon-entry
```

  - `-e SUBCON_CONVERSATION` は環境変数が設定されているときだけ付ける。`-e GEMINI_API_KEY` は値が空でないときだけ、名前だけで付ける（値を引数やログに出さない）
  - 終了コードはエンジンのものをそのまま返す
  - `trap` で、終了時に `<engine> rm -f <name>` を呼ぶ（ランナーが kill されてもコンテナを残さない。失敗しても無視する）

### runners/container-entry.sh（コンテナ内）

- カレントは `/work`（エンジンが `--workdir` で設定済み）。ジョブディレクトリは環境変数 `SUBCON_JOB_DIR`
- 処理は `runners/local` の agy 実行部と同じ: `SUBCON_CONVERSATION` があれば `--conversation` を付け、`agy -p "$(cat "$SUBCON_PROMPT_FILE")" --model "$SUBCON_MODEL" --mode accept-edits --sandbox --settings "$SUBCON_SETTINGS" --output-format stream-json --json-schema "$SUBCON_SCHEMA" --disable-slash-commands --print-timeout "$SUBCON_TIMEOUT"` を実行して `$SUBCON_JOB_DIR/agy.stream` に出す。`agy.json` の抽出（result イベントが無ければ init の会話 ID で ERROR を作る）も local と同じ
- 終了コードは agy のものをそのまま返す

### container/Containerfile

- `FROM debian:bookworm-slim`。`bash` `curl` `git` `jq` `ca-certificates` を入れる
- ユーザー `runner`（ホーム `/home/runner`）を作り、そのユーザーで公式インストーラ `curl -fsSL https://antigravity.google/cli/install.sh | bash` を実行する（バイナリは同梱しない）
- `runners/container-entry.sh` を `/usr/local/bin/subcon-entry` にコピーし、実行可能にする
- `PATH` に `/home/runner/.local/bin` を含める。既定ユーザーは `runner`

合格テストは上位が先に書いてコミット済み（`tests/run.sh` に container グループと `tests/fake-engine` を追加）。現時点で container グループは 5 件全部落ちるのが正しい開始状態（ランナーがまだ無いため）。

## Acceptance
- `tests/run.sh container`
- `tests/run.sh`（既存のテストも全部通ること）

## Notes
- 上記 3 ファイル以外は編集しない（特に `bin/subcon`、`lib/`、`tests/`、`docs/`、`runners/local`）。
- macOS の `/bin/bash` 3.2 で動くこと（連想配列・`mapfile`・`${x,,}` は使わない。`set -u` 下で空配列を `"${a[@]}"` と展開しない）。
- 実エンジンでの煙テストは合格条件に含めない（fake engine で契約の形を検証する。実機確認は上位が別途行う）。
