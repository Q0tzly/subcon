# 35-claude-driver

## Goal

ドライバ層分離の第三段（設計は ../driver-layer.md）。`claude -p`（Claude Code）を subcon の正規の実装役にする `drivers/claude` を実装する。これにより `subcon submit --driver claude` が、agy 互換シムのような橋渡しなしに通る。ベンチマーク（../benchmarks/2026-11-11.md）で実証済みの変換方式を正規ドライバとして書き直すもので、挙動の正はそちらと本票の Interface とする。

## Files

- drivers/claude

## Interface

`drivers/claude`（新規、実行可能ファイル）。補助サブコマンドと本実行の切り分けは票34 の契約どおり（第 1 引数が `preflight` / `models` / `default-model` なら補助動作、それ以外はジョブディレクトリ）。

### preflight

- `claude` が PATH で解決できなければ、標準エラーに `claude not found: install Claude Code and make sure it is on PATH` を出して終了コード 1。
- 解決できたら `claude auth status` を実行する。終了コードが非ゼロ、または出力 JSON の `loggedIn` が `true` でない場合は、標準エラーに `claude is not signed in: run claude auth login` を出して終了コード 1。
- どちらも問題なければ無出力で終了コード 0。

### models / default-model

- `models` は以下の 3 行を TSV で出す（表示名に括弧書きは付けない）:
  - `claude-haiku-5-5` → `Claude Haiku 5.5`
  - `sonnet` → `Claude Sonnet`
  - `opus` → `Claude Opus`
- `default-model` は `claude-haiku-5-5` を出す。

### 本実行

前提は他のドライバと同じ: カレントディレクトリは呼び出し側（ランナー）がジョブの `work/` に設定済み。引数はジョブディレクトリのパス 1 つ（相対なら現行ドライバと同様に正規化する）。

1. **会話 ID の事前確定**: まず会話 ID を決める。
   - `SUBCON_CONVERSATION` が設定されていればそれを使う（resume）。
   - 無ければ UUID を 1 つ生成する。生成手段は `uuidgen`（小文字化する）、`/proc/sys/kernel/random/uuid`、`python3 -c 'import uuid; print(uuid.uuid4())'` の順に試し、最初に成功したものを使う。
   - 決めた ID で、`<job_dir>/agy.stream` の **先頭行** に `{"event":"init","conversation_id":"<id>"}` を書く（claude の起動前に書くこと。途中で kill されても resume 可能に保つため）。
2. **claude の起動**: プロンプトは `SUBCON_PROMPT_FILE` の中身を最後の位置引数として渡す。標準入力は `/dev/null` に繋ぐ。
   - 初回: `claude -p --model "$SUBCON_JOB_MODEL" --output-format json --permission-mode acceptEdits --allowedTools "Read,Edit,Write,Bash,Grep,Glob" --json-schema "$SUBCON_SCHEMA" --session-id "<id>" <MCP フラグ> "<プロンプト>"`
   - resume 時: `--session-id` の代わりに `--resume "$SUBCON_CONVERSATION"` を使う。
   - MCP フラグは環境変数 `SUBCON_CLAUDE_MCP_CONFIG` で決める:
     - 未設定: `--strict-mcp-config --mcp-config '{"mcpServers":{}}'`（既定。ヘッドレス実行の決定性のため MCP を無効化する。2026-11-12 ユーザー決定）
     - `project` という値: MCP フラグを一切付けない（プロジェクトの `.mcp.json` 等、claude の既定動作に任せる）
     - それ以外の値: `--strict-mcp-config --mcp-config "<その値>"`
   - タイムアウト: `SUBCON_TIMEOUT` をそのまま使って `timeout "$SUBCON_TIMEOUT" claude ...` の形で起動する。`timeout` が無ければ `gtimeout` を試し、どちらも無ければラッパーなしで起動する。
   - claude の標準出力はファイルに捕捉する（後段の変換で使う）。捕捉した出力は、init 行に続けて `<job_dir>/agy.stream` へ追記する。標準エラーはそのまま流す。
3. **agy.json への変換**: claude の出力（JSON 封筒）を以下の対応で `<job_dir>/agy.json` に書く。
   - `conversation_id`: 封筒の `session_id`（無ければ手順 1 の ID）。
   - `status`: 封筒の `is_error` が真、または `subtype` が `success` でなければ `"ERROR"`、そうでなければ `"SUCCESS"`。
   - `structured_output`: 封筒の `structured_output` があればそのまま。無ければ封筒の `result` 文字列が JSON オブジェクトとして解釈できる場合にそれを使う。どちらも無ければフィールド自体を入れない。
   - `error`: `status` が `"ERROR"` のときだけ、封筒の `result`（文字列でなければ `subtype`）を入れる。
   - `duration_seconds`: `duration_ms` を 1000 で割った数値。
   - `cost_usd`: `total_cost_usd`（あれば）。
   - `usage`: `input_tokens` ← `usage.input_tokens`、`output_tokens` ← `usage.output_tokens`、`total_tokens` ← 両者の合計、`cache_read_tokens` ← `usage.cache_read_input_tokens`、`thinking_tokens` ← `0`。欠けた項目は 0 として扱う。
   - 封筒として解釈できない出力だった場合は、`{status: "ERROR", conversation_id: "<手順1のID>", error: "claude exited without a result"}` を書く。
4. **終了コード**: 変換後の `status` が `"SUCCESS"` なら 0、そうでなければ 1（claude 自身の終了コードが非ゼロでも、封筒が成功を示すなら 0 として扱う。判定は封筒を正とする）。

## Acceptance

- [ ] `./tests/run.sh driver`
- [ ] `./tests/run.sh`

## Notes

- 本票の実装役は Flash（ユーザー指示、2026-11-12）。
- テストは監督側が用意済み: `tests/fake-claude`（PATH 上の `claude` として振る舞うフェイク）と `tests/run.sh` の `driver` グループ（`test_driver_claude_*`）。テストファイルは変更しないこと。
- 実機での確認（本物の Haiku ジョブを `--driver claude` で 1 本通す）は監督側が実施する。本票の受け入れには含めない。
- container / ci での claude ドライバ対応は範囲外（票34 のガードにより submit 時に止まる）。
