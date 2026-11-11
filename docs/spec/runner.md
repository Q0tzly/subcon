仕様の版: 1

この文書は subcon におけるランナー契約および各ランナーの実装に関する現行仕様の正本である。

# ランナー契約仕様

ランナーは、ジョブ専用の作業ディレクトリ内で agy（エージェントバックエンド）を実行するための実行可能プログラムである。

## 契約本体

すべてのランナーは `runners/<name>` に配置される実行可能ファイルであり、以下の共通契約に従う。

### 引数

- 第 1 引数としてジョブディレクトリのパス（`job_dir`）を 1 つ受け取る（絶対パスまたは相対パス）。

### 前提条件

ランナーが起動される時点で、subcon 本体（`lib/job.sh`）により以下が準備済みである:

1. `work/`: ジョブ専用の作業ディレクトリ（worktree または隔離 clone）。
2. `meta.json`: ジョブのメタデータ。
3. `ticket.md`: 発行対象となった作業票の内容。
4. `prompt.txt`: agy に渡すプロンプト（`SUBCON_PROMPT_FILE` が指すファイル）。

### 責務

- `work/` をカレントディレクトリとして agy を実行する。
- agy の最終出力をジョブディレクトリ直下の `agy.json` に書き出す。
  - agy が途中で強制終了（kill 等）された場合でも、会話 ID が取得できていれば `{status: "ERROR", conversation_id: "...", error: "agy exited without a result"}` を `agy.json` に書き出す。
- ジョブディレクトリ内に書き出すのは、`agy.json` およびランナー固有のログファイル（`agy.stream` 等）に限定する（パッチの生成やチェック、`result.json` の書き出しはホスト側の subcon が行う）。
- ランナーの標準出力は回収されない。ジョブの `log` ファイルに残るのは標準エラー出力のみであり、診断情報は標準エラー出力へ書くこと。
- subcon はジョブの終了・破棄時にランナーへ SIGTERM を送ることがある。ランナーは SIGTERM を受けたら子プロセスを含めて速やかに（目安として 5 秒以内に）終了すること。

### 終了コード

- agy が成功終了した場合は終了コード `0` を返す。
- agy がエラー終了または異常終了した場合は、非ゼロの終了コード（agy の終了コード、または 1）を返す。

## 環境変数一覧表

### 契約環境変数（subcon 本体が設定し、ランナーが受け取る変数）

| 変数名 | 設定する側 | 意味 |
| --- | --- | --- |
| `SUBCON_PROMPT_FILE` | subcon 本体 | agy に渡すプロンプトファイルの絶対パス（前文と票、または resume プロンプトが書き込まれている） |
| `SUBCON_SCHEMA` | subcon 本体 | バックエンドの報告フォーマットを強制する JSON スキーマファイルのパス（`schema/result.schema.json`） |
| `SUBCON_SETTINGS` | subcon 本体 | agy のツール権限制御設定 JSON 文字列（git 破壊的操作の拒否リストなど） |
| `SUBCON_JOB_MODEL` | subcon 本体 | ジョブで実行する agy のモデル ID（例: `gemini-3.8-flash-medium`） |
| `SUBCON_TIMEOUT` | subcon 本体 | agy の `--print-timeout` に指定するタイムアウト文字列（例: `30m`） |
| `SUBCON_CONVERSATION` | subcon 本体 | 再開（`resume`）時に引き継ぐ agy の会話 ID（初回実行時は未設定） |

### 実装内部の環境変数（ランナーの実装や CI 内部でのみ使われる変数）

| 変数名 | 設定する側 | 意味 |
| --- | --- | --- |
| `SUBCON_ROOT` | subcon 本体 / スクリプト | subcon のインストール・リポジトリのルートパス |
| `SUBCON_JOB_DIR` | `runners/container` | コンテナ内のエントリスクリプト（`runners/container-entry.sh`）にジョブディレクトリのコンテナ内パス（`/job`）を伝える変数 |
| `SUBCON_CI_JOB` | CI ワークフロー | `ci/run-job.sh` に渡すジョブ ID |
| `SUBCON_CI_TICKET` | CI ワークフロー | `ci/run-job.sh` に渡す票のパス |
| `SUBCON_CI_BASE` | CI ワークフロー | `ci/run-job.sh` に渡すベースコミットハッシュ |
| `SUBCON_CI_MODEL` | CI ワークフロー | `ci/run-job.sh` に渡すモデル ID |
| `SUBCON_CI_TIMEOUT` | CI ワークフロー | `ci/run-job.sh` に渡すタイムアウト文字列 |
| `SUBCON_CI_POLL` | テスト / 内部 | `runners/ci` のポーリング間隔秒数（既定: 5 秒、通常の利用では設定不要） |

## ランナーごとの拡張

### local ランナー (`runners/local`)

ホスト上の環境で直接 agy を実行する標準ランナー。

- **stream-json と会話 ID の回収**:
  - agy を `--output-format stream-json` で起動し、出力を `agy.stream` に保存する。
  - stream-json の最初の `init` イベントから `conversation_id` を取得する。
  - 最後の `result` イベントから `structured_output` 等を含む JSON を抽出し、`agy.json` に書き出す。
  - agy が結果を出力する前に SIGKILL 等で停止した場合でも、`init` イベントで得られた `conversation_id` を用いて `{status: "ERROR", conversation_id: "...", error: "agy exited without a result"}` を `agy.json` に保存することで、後から `subcon resume` による再開を可能にする。

### container ランナー (`runners/container`)

Docker または Podman を用いて使い捨てコンテナ内で agy を実行する隔離ランナー。

- **マウント構成**:
  - `$job_dir/work` → `/work`（rw、作業ディレクトリ）
  - `$job_dir` → `/job`（rw、ログ出力およびスキーマ配置）
  - `$HOME/.gemini` → `/home/runner/.gemini`（rw、認証情報および会話 DB）
- **環境変数の変換**:
  - コンテナ内のパスに合わせてパス変数を変換して渡す（`SUBCON_PROMPT_FILE=/job/prompt.txt`, `SUBCON_SCHEMA=/job/schema.json`）。
  - ホスト側の uid:gid（`--user "$(id -u):$(id -g)"`）でコンテナを実行し、ホストとコンテナの間でファイルの所有者不整合が起きないようにする。
- **イメージ作成の要点**:
  - `container/Containerfile` からビルドする。
  - agy バイナリはイメージに同梱せず、ビルド時に公式インストーラ（`https://antigravity.google/cli/install.sh`）経由で取得する（再配布禁止規約に準拠）。
  - Debian bookworm（glibc 2.28 以上）をベースとし、git, jq, curl を含む。
  - コンテナ内 git の誤動作防止のため、コンテナ側の git 設定で `safe.directory`（`/work`）を設定する。

### ci ランナー (`runners/ci`)

GitHub Actions の self-hosted ランナー上でジョブを実行するリモート拡張ランナー。

- **ワークフロー契約**:
  - 利用者リポジトリ側のワークフローの配置は `.github/workflows/subcon-job.yml`。
  - `workflow_dispatch` の入力は `job` / `ticket` / `base` / `model` / `timeout` の 5 つ。
- **run-name による相関**:
  - `gh workflow run subcon-job.yml` を呼び出してリモートワークフローを起動する。
  - ワークフローの `run-name` に `subcon <job-id>` を含めることで、ジョブ ID と Actions の実行（run）を確実に相関させ、完了をポーリング監視する。
- **artifact の形式**:
  - CI 上のスクリプト（`ci/run-job.sh`）は成果物を名前 `subcon-artifact` の artifact としてアップロードする。
  - 成果物 `subcon-artifact` の中身:
    - `work.tar.gz`: 変更後の `work/` ディレクトリ全体をトップに含む tar アーカイブ。
    - `agy.json`: agy の実行結果（生成されている場合）。
    - `agy.stream`: agy のイベントストリームログ（生成されている場合）。
  - ホスト側ランナーは artifact をダウンロードし、`tar --no-same-owner -xzf` でジョブディレクトリの `work/` に展開復元し、`agy.json` と `agy.stream` を配置する。
- **resume の制限**:
  - CI ランナーでは `subcon resume` による再開は不可（会話 DB はリモートの CI マシン側にのみ保存され、ホスト側での前回収穫パッチの適用と噛み合わないため）。
