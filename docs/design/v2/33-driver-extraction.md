# 33-driver-extraction

## Goal

ドライバ層分離の第一段（設計は ../driver-layer.md）。現在 `runners/local` と `runners/container-entry.sh` に複製されている agy 起動ブロックを新設の `drivers/agy` へ抽出し、ランナー側は「作業ディレクトリへ入ってドライバを呼ぶ」だけにする。あわせて `meta.json` に `driver` を記録し始める。外部挙動の変更はこの記録追加と `SUBCON_SETTINGS` の共有 env からの除去のみで、それ以外は現行と同一に保つリファクタである。

## Files

- drivers/agy
- runners/local
- runners/container-entry.sh
- container/Containerfile
- lib/job.sh
- lib/common.sh

## Interface

- `drivers/agy`（新規、実行可能ファイル）:
  - 引数はジョブディレクトリのパス 1 つ（絶対・相対どちらでも受け、現行 `runners/local` と同じ方法で絶対パスに正規化する）。
  - 前提: カレントディレクトリは呼び出し側（ランナー）がジョブの `work/` に設定済みとする。ドライバ自身は `cd` しない。
  - 中身は現行 `runners/local` の以下の部分をそのまま移したものとする:
    - 冒頭の agy PATH フォールバック（PATH に無ければ `~/.local/bin/agy` を PATH に足す）。
    - `SUBCON_CONVERSATION` があれば `--conversation <id>` を付ける resume フラグの組み立て。
    - agy の起動: `agy -p "$(cat "$SUBCON_PROMPT_FILE")" --model "$SUBCON_JOB_MODEL" --mode accept-edits --sandbox --settings <後述> --output-format stream-json --json-schema "$SUBCON_SCHEMA" --disable-slash-commands --print-timeout "$SUBCON_TIMEOUT"`、標準出力を `<job_dir>/agy.stream` へ。
    - 最後の `result` イベントの `.result` を `<job_dir>/agy.json` へ抽出。空なら `init` イベントの `conversation_id` を使って `{status: "ERROR", conversation_id: ..., error: "agy exited without a result"}` を書き、会話 ID も無ければ `agy.json` を残さない。
    - 終了コードは agy の終了コードをそのまま返す。
  - `--settings` の値は環境変数からではなく、ドライバ内の定数として持つ。値は現行 `lib/common.sh` の `SUBCON_SETTINGS` と同一の JSON 文字列（git 破壊的操作の拒否リスト）。
- `runners/local`:
  - ジョブディレクトリの正規化・存在確認と `cd "$job_dir/work"` までは現行どおり。
  - 以後はドライバを `exec` する。ドライバのパスは自ファイルの位置から解決する: `driver_bin="$(cd "$(dirname "$0")/.." && pwd)/drivers/${SUBCON_DRIVER:-agy}"` とし、`exec "$driver_bin" "$job_dir"`。
  - agy 起動ブロックと `SUBCON_SETTINGS` への言及は残さない。
- `runners/container-entry.sh`:
  - agy 起動ブロックをドライバ呼び出しに置き換える。コンテナ内ではドライバは `subcon-driver-agy` の名前で PATH 上に置かれる（Containerfile が配置）。呼び出しは `driver_bin="${SUBCON_DRIVER_BIN:-subcon-driver-agy}"` とし、`"$driver_bin" "$job_dir" || rc=$?` の形で終了コードを受け、最後に `exit "$rc"` する（entry は `set -euo pipefail` のため、非ゼロで即終了させない）。
  - 冒頭の agy PATH フォールバックはドライバ側へ移るので entry からは消す。entry は現行どおり `cd` しない（コンテナの作業ディレクトリが `/work` 前提）。
- `container/Containerfile`:
  - entry の COPY の隣に `COPY drivers/agy /usr/local/bin/subcon-driver-agy` と `RUN chmod 755 /usr/local/bin/subcon-driver-agy` を追加する。
- `lib/job.sh`:
  - ジョブ作成時の `meta.json` 生成（`json_out` のオブジェクト）に `driver: "agy"` を追加する（`--arg driver agy` を渡し、リテラルに `driver: $driver` を含める）。この票では値は常に `agy` 固定（選択の一般化は票34）。
  - `job_exec` で meta から `driver` を読み（`jq -r '.driver // "agy"'`、旧ジョブ互換のため既定 `agy`）、ランナー起動前に `export SUBCON_DRIVER="$driver"` する。
  - `job_exec` の `export SUBCON_SETTINGS=...` の行は削除する（渡す先が無くなる）。
- `lib/common.sh`:
  - `SUBCON_SETTINGS` 定数を削除する。削除前に他ファイルから参照されていないことを確認すること（参照が残る場合は消さず、その旨を `design_questions` に記録する）。

## Acceptance

- [ ] `./tests/run.sh submit`
- [ ] `./tests/run.sh container`
- [ ] `./tests/run.sh`
- [ ] `test -x drivers/agy && ! grep -q 'output-format stream-json' runners/local runners/container-entry.sh`

## Notes

- 振る舞い無変更が原則。既存テストは変更しない（監督側が追加した `test_submit_driver_meta` と `test_container_entry_uses_driver` が最初から入っている）。既存テストが落ちたら抽出のミスとして本票の範囲で直すこと。
- 仕様書（`docs/spec/runner.md` の `SUBCON_SETTINGS` 記載など）の追従は本票では行わない。後続の仕様票でまとめて扱う（票30・31 の分担と同じ）。
- container の実機確認（イメージ再ビルド＋実ジョブ）はこの実行環境ではできない。entry の単体テスト（fake-agy 経由）までが本票の受け入れで、実機確認は監督側が別途行う。
- ドライバ選択の一般化（`--driver`、`preflight`、`models`）は票34、`drivers/claude` は票35。本票で先取りしない。
