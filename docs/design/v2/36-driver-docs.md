# 36-driver-docs

## Goal

票33〜35（ドライバ層分離）の文書追従。実装済みの `--driver` / `SUBCON_DRIVER` とドライバ契約が、現行仕様の正本（`docs/spec/`）と README にまだ載っていない箇所を埋め、利用者から見える説明を実装と一致させる。挙動の変更はしない（`bin/subcon` は usage の 1 行のみ）。

## Files

- docs/spec/cli.md
- docs/spec/runner.md
- docs/spec/files.md
- README.md
- bin/subcon

## Interface

### docs/spec/cli.md

1. コマンド一覧の行を実装に合わせる:
   - `submit` 行と `run` 行に `[--driver D]` を追加する（現行: `[--runner R] [--model M] [--timeout T]` → `[--runner R] [--model M] [--driver D] [--timeout T]`）。
   - `trailer` 行を `subcon trailer [--model M] [--driver D]` にする。
   - `resume` 行の説明「agy の会話履歴を引き継いで」を「元のジョブのドライバの会話履歴を引き継いで」にする。
2. 一覧の直後にある「agy の解決を必要とするコマンド…」の段落を、ドライバの事前確認（preflight）の説明に書き換える。要点: 対象コマンド（`submit`, `run`, `resume`, `commit`, `reject`, `trailer`）は実行前に選択中ドライバ（既定 `agy`、`resume` は元ジョブに記録されたドライバ）の `preflight` を呼び、実行できなければ処理を開始せず終了コード 1 で失敗する。agy ドライバの場合は従来どおり `agy not found` を含む。
3. 「主なオプション」に `--driver D` の項目を追加する。要点: 実装役ドライバを指定する（`drivers/` 配下の名前）。使えるコマンドは `submit` / `run` / `trailer`（`resume` は元ジョブのドライバに固定、`reject` は元ジョブのドライバで再委任）。既定値は環境変数 `SUBCON_DRIVER` の値、未設定時は `agy`。`container` / `ci` ランナーは `agy` ドライバのみ対応し、それ以外は submit 時に終了コード 1 で失敗する。
4. 「主なオプション」の既存項目を一般化する:
   - `--model M`: 「agy に渡すモデル ID」→「選択したドライバに渡すモデル ID」。既定値はドライバごとに決まる（`agy`: `gemini-3.8-flash-medium`、`claude`: `claude-haiku-5-5`）旨と、`SUBCON_MODEL` で上書きできる旨を書く。
   - `--timeout T`（submit / run / resume）: 「agy の `--print-timeout` に渡す」→「ドライバに渡すタイムアウト文字列」。
5. 「利用者向け環境変数」に追加・修正する:
   - `SUBCON_DRIVER` を追加する: 既定で使うドライバ名（未設定時は `agy`）。
   - `SUBCON_MODEL` の説明を「既定で使用するモデル ID（意味は選択中ドライバのモデル ID 空間）」に一般化する。
   - `SUBCON_CLAUDE_MCP_CONFIG` を追加する: `claude` ドライバの MCP 設定の上書き口。未設定時は MCP を無効化（厳格・空）、`project` のときは claude の既定動作、それ以外の値は MCP 設定 JSON として渡す。
6. 終了コード表のバックエンド呼称を一般化する: コード 2 の「Flash（バックエンド）」→「実装役（バックエンド）」、コード 4 の「agy の実行失敗」→「バックエンドの実行失敗」。

### docs/spec/runner.md

1. 契約環境変数の一覧表に `SUBCON_DRIVER` の行を追加する（設定する側: subcon 本体。意味: 選択されたドライバ名。ランナーは `drivers/<name>` を起動する）。
2. 同表の既存行の「agy」呼称を一般化する: `SUBCON_PROMPT_FILE` は「バックエンドに渡すプロンプトファイル」、`SUBCON_JOB_MODEL` は「ジョブで実行するドライバのモデル ID」、`SUBCON_TIMEOUT` は「ドライバに渡すタイムアウト文字列」、`SUBCON_CONVERSATION` は「引き継ぐドライバの会話 ID」。
3. ランナー契約の本文（「`prompt.txt`: agy に渡すプロンプト」）と local ランナー節の「直接 agy を実行する」も同様にバックエンド／ドライバの呼称へ一般化する。container / ci 節の agy 記述は現行仕様どおり（agy のみ対応）なので変更しない。

### docs/spec/files.md

1. `meta.json` の例に `"driver": "agy"` を追加する（`runner` の直後）。
2. フィールド一覧に `driver` の項目を追加する: 使用したドライバ名（文字列、例: `"agy"`, `"claude"`）。
3. resume 時の追加フィールドの `conversation` の説明「agy の会話 ID」→「ドライバの会話 ID」。

### README.md

1. 冒頭の説明にドライバ選択を反映する: 既定は agy 経由の Gemini Flash、`--driver claude` で Claude Code（Haiku）も実装役に選べる旨を 1〜2 文で足す。「Flash が実装し」の部分はドライバ一般の言い方に寄せてよいが、文の構造は大きく変えない。
2. セットアップの前提行: 「`agy`（ログイン済み）と `jq`」→ ドライバに応じた前提（`agy` または `claude`、いずれもログイン済み）と `jq` が要る形にする。
3. 「使い方」の直後（container ランナー節の前）に「ドライバ」節を新設する。要点:
   - `--driver <name>` / 環境変数 `SUBCON_DRIVER` で実装役を選ぶ。既定は `agy`。
   - `agy`: Gemini Flash（既定モデル `gemini-3.8-flash-medium`）。`claude`: Claude Code（既定モデル `claude-haiku-5-5`）。
   - `container` / `ci` ランナーは `agy` ドライバのみ対応。
   - `resume` は元ジョブのドライバで固定される。
4. 「ほかに」の列挙にある resume の説明「失敗したジョブを agy の会話ごと再開」→「失敗したジョブをドライバの会話ごと再開」。

### bin/subcon

- usage の trailer 行のみ変更する: `subcon trailer [--model M]` → `subcon trailer [--model M] [--driver D]`。他の行・コードは触らない。

## Acceptance

- [ ] `grep -q -- '--driver' docs/spec/cli.md`
- [ ] `grep -q 'SUBCON_DRIVER' docs/spec/cli.md`
- [ ] `grep -q 'SUBCON_DRIVER' docs/spec/runner.md`
- [ ] `grep -q '"driver"' docs/spec/files.md`
- [ ] `grep -q -- '--driver' README.md`
- [ ] `grep -q 'SUBCON_DRIVER' README.md`
- [ ] `grep -q 'trailer \[--model M\] \[--driver D\]' bin/subcon`
- [ ] `./tests/run.sh`

## Notes

- 本票の実装役は Haiku（subcon シム経由。ユーザー指示 2026-11-12: Haiku を第一とし、尽きたら Flash）。
- 文書票である。コードの挙動を変えないこと。`docs/design/` 配下の履歴文書（v2.md、container-runner.md、driver-layer.md 等）は書き換えない（現行の説明だけを直すのが repo のルール）。
- 戦略・価格・収益化の話は書かない（README は公開文書）。
- 既定ドライバは `agy`（Flash）のまま継続する（2026-11-12 ユーザー決定、driver-layer.md の決定事項 3）。文書でも既定は agy と明記する。
