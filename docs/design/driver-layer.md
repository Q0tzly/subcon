# ドライバ層の分離と Claude ドライバ（フェーズ6 第一段）

状態: 設計（2026-11-12、上位が起草。ユーザーの方向決定済み、票は未作成）

## 目的

subcon の実装役は現在 agy 前提に固定されている。「どこで動かすか」（ランナー）と
「どのエージェント CLI を回すか」（ドライバ）を分離し、agy 以外の実装役
（第一号として `claude -p` / Haiku）を正規の選択肢にする。

根拠は 2026-11-11 のベンチマーク（`docs/benchmarks/2026-11-11.md`）:

- agy 互換シム経由で subcon の通常経路に載せた Haiku は、票03/04/11/20/25 の
  全てで Flash より高速・低コストで、実装の正しさでも劣らなかった。
- Haiku の `partial` はいずれも実装不足ではなく、票・テスト・環境側の問題の
  正確な切り分けと申告だった。一方 Flash は票11 でホスト環境への無申告の
  細工、票20 でテスト専用変数を嗅ぐ特例コードという、無人運用では
  検収コストが高い失敗の仕方をした。
- つまり「実装役を選べる」ことは将来の一般化ではなく、現時点の品質・
  コストに直結する。

## 現状の agy 結合マップ（2026-11-12 実測）

ホスト側:

| 箇所 | agy 依存の内容 |
| --- | --- |
| `lib/common.sh` `agy_bin` / `require_agy` | バイナリ探索（PATH、`~/.local/bin/agy`）と不在時の打ち切り |
| `lib/common.sh` `agy_auth_mode` / `warn_consumer_auth` | 消費者ログインの検出と規約警告 |
| `lib/common.sh` `model_name` | `agy models` の TSV を引いて表示名を解決（commit の trailer が使用） |
| `lib/common.sh` の `SUBCON_SETTINGS` 定数 | agy のツール権限 JSON（git 破壊的操作の拒否リスト） |
| `lib/job.sh` | submit/run での `require_agy` 呼び出し、ジョブ実行時の契約 env 組み立て |
| `lib/job.sh` `job_finalize` / `lib/history.sh` | `agy.json` の `structured_output` / `conversation_id` / `error` / `usage` / `duration_seconds` の解釈 |

実行側:

| 箇所 | agy 依存の内容 |
| --- | --- |
| `runners/local` | agy 起動ブロックそのもの（stream-json → `agy.stream` → `agy.json` 抽出、kill 時も会話 ID を残す処理） |
| `runners/container-entry.sh` | ↑と同一の起動ブロックの複製 |
| `runners/container` | `~/.gemini`（agy 認証・会話 DB）のマウント |
| `runners/ci` + `ci/run-job.sh` | CI 側で `runners/local` を再利用するため間接的に agy 前提。成果物名も `agy.json` / `agy.stream` |
| `container/Containerfile` | agy を公式インストーラで取得（再配布禁止規約への準拠）。同梱するのは entry スクリプトのみ |

テスト側: `tests/fake-agy` は既に「ドライバ形」のフェイクであり、本設計は
この形を正式な契約に格上げするものとも言える。

## 責務分界

- **ランナー**（現行どおり）: 実行環境の用意と回収。worktree / clone の準備、
  コンテナの起動、CI の dispatch と成果物回収、SIGTERM の伝播。
  エージェント CLI のことは知らない。
- **ドライバ**（新設）: エージェント CLI の起動と結果の正規化。
  `drivers/<name>` の実行可能ファイルが担う。実行環境の中で
  （local ならホスト、container ならコンテナ内、ci なら CI マシン上で）
  ランナーから呼ばれる。
- **ホスト（lib/）**: 票・プロンプト・スキーマの供給、ドライバ選択と
  事前確認の调度、終了後の検収（パッチ生成・Acceptance 再実行・履歴記録）。
  `agy.json` の解釈は現行のまま（後述の互換方針）。

## ドライバ契約

### 起動

- ランナーはカレントディレクトリを `work/` にして
  `drivers/<name> <job_dir>` を実行する（引数・前提条件はランナー契約と同型）。
- ドライバの選択はホストが環境変数 `SUBCON_DRIVER` でランナーに伝える。
  あわせて `meta.json` に `driver` を記録する（後述）。

### 入力（環境変数）

現行の契約 env のうち、以下はドライバ契約として引き継ぐ:

- `SUBCON_PROMPT_FILE`（プロンプトの絶対パス）
- `SUBCON_SCHEMA`（報告スキーマのパス）
- `SUBCON_JOB_MODEL`（そのドライバのモデル ID 空間での ID）
- `SUBCON_TIMEOUT`（タイムアウト文字列。そのまま使えない CLI では
  ドライバが `timeout` 等で等価に実現する）
- `SUBCON_CONVERSATION`（resume 時のみ。そのドライバの会話 ID）

`SUBCON_SETTINGS` は agy 固有（権限 JSON）なので共有契約から外し、
`drivers/agy` が内部で同じ JSON を構成する。

### 出力

- `agy.json`: 最終結果。形は `docs/spec/backend.md` の「subcon が解釈する項目」
  そのまま（`status`、`conversation_id`、`structured_output`、`error`、
  `usage`、`duration_seconds`、任意で `cost_usd`）。
- `agy.stream`: 実行トランスクリプト。形式はドライバ固有でよいが、
  **会話 ID は実行の早い段階でここ（または `agy.json`）から回収可能で
  なければならない**。kill されたジョブを resume 可能に保つための要件。
- ジョブディレクトリへの書き出しはこの 2 ファイルに限る（現行ランナー契約と同じ）。

ファイル名の互換方針: `agy.json` / `agy.stream` という名前は名残になるが、
票25 で固定したばかりのファイル形式（`docs/spec/files.md`）と履歴解析を
壊さないため、本フェーズでは改名しない。意味は「ドライバの結果／
トランスクリプト」と読み替える。改名は形式の版を上げる機会が別途あれば
その時に検討する。

### 終了コード

- エージェントが完走したら（報告の status が何であれ）`0`。
- エージェント自体のエラー・異常終了は非ゼロ。
  （現行ランナー契約と同じ。`job_finalize` の判定は無変更。）

### 補助サブコマンド

ドライバは引数なしの本実行に加え、以下を持つ:

- `drivers/<name> preflight`: そのドライバで実行可能かをホスト側から
  確かめる。実行可なら終了コード 0、不可なら理由を標準エラーに書いて非ゼロ。
  ホストはジョブを作る前にこれを呼ぶ（現行の `require_agy` /
  `require_container` / `require_ci` と同じ位置づけ）。
- `drivers/<name> models`: モデル一覧を `id<TAB>表示名` の TSV で出す。
  ホストの `model_name` は選択中ドライバのこれを引く。

### 会話と resume

- 会話 ID はドライバの名前空間に閉じる。`meta.json` の `driver` と組で
  意味を持つため、resume は記録されたドライバでしか行わない。
- ci ランナーの resume 不可は現行どおり（ドライバによらない）。

## ドライバ選択とモデル

- 選択手段: `submit` / `run` の `--driver <name>` と環境変数
  `SUBCON_DRIVER`。既定は `agy`（現行挙動と同一）。
- `meta.json` に `driver` を追加する。読み手は未知フィールドを無視する
  前方互換が既にあるため、形式の版は上げない。
- モデル: `SUBCON_MODEL` / `--model` の意味は「選択中ドライバのモデル ID」
  に変わる。未指定時の既定モデルはドライバごとに持つ
  （agy: `gemini-3.8-flash-medium`、claude: `claude-haiku-5-5`）。
- 認証警告: 消費者ログイン警告は agy ドライバ選択時のみ（現行どおり）。
  claude ドライバでは `preflight` が `claude auth status` のログイン状態を見る。

## drivers/claude の要領（票35 の設計）

ベンチ用シム（実験コード）で実証済みの変換を、正規ドライバとして書き直す:

- 起動: `claude -p --model <id> --output-format json
  --permission-mode acceptEdits
  --allowedTools "Read,Edit,Write,Bash,Grep,Glob"
  --json-schema <schema> --session-id <uuid>`、標準入力は閉じる。
  タイムアウトは `timeout` コマンドで `SUBCON_TIMEOUT` を秒換算して課す。
- **会話 ID は事前に確定する**: ドライバが UUID を生成し、開始直後に
  `agy.stream` へ init 相当の行を書いてから `--session-id <uuid>` で起動する。
  これにより kill 時も resume 可能（シムの既知の弱点の解消）。
  resume は `--resume <id>`。
- 変換: claude の JSON 封筒（`result`、`session_id`、`duration_ms`、
  `total_cost_usd`、`usage`、`structured_output`）を `agy.json` の形へ写す。
  `usage` のキー名は backend 仕様の名前に揃える
  （`cache_read_tokens` は claude 側 `cache_read_input_tokens` から）。
- MCP: ヘッドレス実行の決定性のため、既定で
  `--strict-mcp-config --mcp-config '{"mcpServers":{}}'` を付ける。
  根拠: 対話用に同期されたプラグイン MCP が認証試行を繰り返し、
  実務上ノイズ（承認カード連発）になることを 2026-11-11 に実測した。
  プロジェクトの `.mcp.json` を使いたい場合の逃げ道として
  環境変数での上書き口を 1 つ用意する（名前は票35 で確定）。

## 移行計画（票の分割）

番号は 33 から。いずれも受け入れは「全テスト合格＋該当グループ合格」を基本とし、
33 は振る舞い無変更のリファクタとして単独で緑を保つ。

### 票33: ドライバ抽出（agy の分離、振る舞い無変更）

- 新設 `drivers/agy`: `runners/local` の agy 起動ブロックと
  `SUBCON_SETTINGS` の構成を移す。
- `runners/local` と `runners/container-entry.sh` は「work に入って
  ドライバを呼ぶ」だけの薄い実装にし、重複を消す。
- `container/Containerfile`: `drivers/agy` もイメージに同梱する。
- ホスト側は現行の `require_agy` 等をまだ使う（選択の一般化は票34）。
  ただしジョブ実行時の env に `SUBCON_DRIVER=agy` を足し、`meta.json` に
  `driver: "agy"` を記録し始める。
- テスト: 既存スイートが無変更で全て通ることが受け入れ条件。
  `tests/fake-agy` の注入経路（PATH 上の `agy`）は `drivers/agy` 経由でも
  そのまま効くこと。

### 票34: ドライバ選択と事前確認の一般化

- `--driver` / `SUBCON_DRIVER`、`meta.driver` の読み書き、resume 時の
  ドライバ固定。
- `require_driver`: `drivers/<name>` の存在確認＋ `preflight` 呼び出しに
  一般化。agy の消費者警告は driver=agy のときだけ現行位置で出す。
- `model_name` をドライバの `models` 経由に一般化（trailer の表示名解決）。
- 既定モデルのドライバ別解決。
- テスト: 新グループ `driver`（フェイクドライバでの選択・preflight 失敗・
  未知ドライバ・resume のドライバ固定・trailer の名前解決）。

### 票35: drivers/claude 本実装

- 上記「要領」の実装と `preflight` / `models`。
- テスト: `tests/fake-claude`（封筒の成功／エラー／構造化出力なし／
  kill 相当の途中終了を再現）で変換・会話 ID の事前確定・resume・
  usage 写像を検証する。
- 実機確認: この VM で実 Haiku ジョブ 1 本（票03 級）を通し、シム版との
  結果一致を見る（監督側の手作業確認として票の Notes に残す）。

### この設計の範囲外（後続）

- container / ci での claude ドライバ対応（イメージへの claude 同梱と
  認証の持ち込み、CI マシン側の claude 認証が別途必要）。
- OpenCode 等の第三ドライバ、ドライバの外部配布（プラグイン形式）。
- Go 化（フェーズ C 着手前という既定方針どおり、本分離とは別軸）。

## 未決事項（ユーザーの判断）

1. MCP の既定（厳格・空）を出荷既定にしてよいか。代替は「プロジェクトの
   `.mcp.json` を尊重し、プラグインノイズは利用者側の設定に委ねる」。
2. ドライバ選択の既定を将来 `claude` に切り替えるかは、票35 の実機確認と
   しばらくの併用実績を見てから別途判断する（本設計では既定は `agy` のまま）。
