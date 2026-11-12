仕様の版: 1

この文書は subcon の CLI インターフェースに関する現行仕様の正本である。

# CLI 仕様

## コマンド一覧

すべてのコマンドは git リポジトリ内で実行する（例外: `guide`、`trailer`、`stats --all`、および `export --all`）。

| コマンド | 動作 | stdout の形式 |
| --- | --- | --- |
| `subcon new <feature>/<NN-name>` | `docs/design/<feature>/<NN-name>.md` をテンプレートから生成する。既にファイルが存在する場合はエラー | 単体オブジェクト: `{"path": "..."}` |
| `subcon submit [--runner R] [--model M] [--driver D] [--timeout T] [--issue <ref>] <ticket>...` | 全票を検証した後、票ごとにジョブを作成してバックグラウンドで実行を開始する。作成したジョブの `## Files` が同じリポジトリの実行中（queued / running）の他ジョブと重なる場合は、stderr に重なったジョブごとに警告を 1 行出す（終了コードには影響しない）。環境変数 `SUBCON_BUDGET_TOKENS` / `SUBCON_BUDGET_JOBS` が設定されている場合、今月（UTC）の終了ジョブの合計トークン数または件数が上限以上なら、ジョブを 1 つも作らず終了コード 1 で失敗する（`run` も同じ。`resume` は対象外）。上限値が非負整数でなければ、処理を始めずに終了コード 1 で失敗する | 配列: `[{"ticket": "...", "id": "..."|"null", "error": "..."|"null"}]` |
| `subcon wait [--timeout T] <id>...` | 指定した全ジョブの完了を待機する | 配列: 各ジョブの結果オブジェクト `[{"v": 1, ...}, ...]` |
| `subcon run [--runner R] [--model M] [--driver D] [--timeout T] [--issue <ref>] <ticket>` | 票 1 枚を `submit` し、完了するまで `wait` する | 単体オブジェクト: ジョブの結果オブジェクト `{"v": 1, ...}` |
| `subcon resume [--timeout T] <id>` | 失敗したジョブを、元のジョブのドライバの会話履歴を引き継いで新しいジョブとして再開する | 配列: `[{"ticket": "...", "id": "..."|"null", "resume_of": "...", "error": "..."|"null"}]` |
| `subcon show <id>` | 指定したジョブの結果を表示する。実行中の場合は `state` だけが埋まった結果を返す | 単体オブジェクト: ジョブの結果オブジェクト `{"v": 1, ...}` |
| `subcon list [--all]` | 現在のリポジトリのジョブ一覧を表示する。`--all` を指定した場合は全リポジトリのジョブを対象とする（表示のみ） | 配列: `[{"id": "...", "repo": "...", "ticket": "...", "state": "...", "status": "..."|"null", "created_at": "..."}]`（作成日時の降順） |
| `subcon diff <id>` | ジョブの `patch.diff` をそのまま出力する | テキスト: Unified diff 形式（パッチテキスト） |
| `subcon log <id>` | ジョブの実行ログ（ジョブディレクトリの `log` ファイル）をそのまま出力する。実行中のジョブでも読める | テキスト: ログテキスト |
| `subcon apply <id>` | ジョブのパッチを現在の作業ツリーに適用する（インデックスは触らず、コミットはしない） | 単体オブジェクト: `{"id": "...", "applied": true}` |
| `subcon commit -m <message> [--edited] <id>` | 検収済みの変更をステージングし、trailer（`Co-Authored-By` / `Reviewed-By`、および issue 参照がある場合は `Closes`）を付与してコミットする | 単体オブジェクト: `{"id": "...", "commit": "<hash>"}` |
| `subcon checks <id>` | 終了済みジョブ（`finished` または `failed`）の checks を現在の repo にある票ファイルから再計算して result.json を更新する | 単体オブジェクト: 更新後の checks オブジェクト |
| `subcon reject -m <reason> [--model M] [--runner R] <id>` | 差し戻し理由を票の `## Notes` に追記してコミットし、同一票を再委任する | 単体オブジェクト: `{"id": "..."|"null", "reject_of": "...", "ticket": "...", "error": "..."|"null"}` |
| `subcon discard <id>...` | 指定したジョブの作業領域およびジョブディレクトリを削除する。実行中のプロセスは停止させる | 単体オブジェクト: `{"discarded": ["<id>", ...]}` |
| `subcon stats [--all] [--since <N>d\|<N>h] [--text]` | 履歴ファイル（`history.jsonl`）を集計して統計を出力する | 単体オブジェクト: 集計 JSON（`--text` 指定時は人間向けのテキスト表） |
| `subcon export [--all] [--since <N>d\|<N>h]` | 履歴ファイルのジョブ行をメタデータとして出力する（機械向けエクスポート）。先頭 1 行がエンベロープ、以降はジョブ行。既定は現在のリポジトリのジョブのみ、`--all` で全リポジトリ。`--since` は `created_at` が cutoff 以降のジョブに絞る。履歴が無い場合はエンベロープのみ | JSON Lines: 1 行目 `{"type": "export", ...}`、以降は履歴のジョブ行（形式は `docs/spec/files.md` の「エクスポート形式」） |
| `subcon guide` | 委任ルール文書（`docs/delegation.md`）を表示する | テキスト: Markdown |
| `subcon trailer [--model M] [--driver D]` | コミットメッセージに付与する `Co-Authored-By` 行を表示する。ドライバ・モデルは `--driver` / `--model` > 環境変数 `SUBCON_DRIVER`（モデルは `SUBCON_MODEL` も含む既定）> このリポジトリの直近ジョブ（ドライバとモデル）> `agy` の順に決める | テキスト: `Co-Authored-By: <Model Name> <email>` |

ドライバの事前確認（preflight）: `submit`, `run`, `resume`, `commit`, `reject`, `trailer` は、実行前に選択中ドライバ（既定は `agy`、`resume` は元ジョブに記録されたドライバ）の `preflight` を呼ぶ。実行できない場合は処理を開始せず、終了コード 1 で失敗する。agy ドライバの場合は `PATH` または `$HOME/.local/bin/agy` からバイナリを解決し、見つからなければ `agy not found` を含むエラーで失敗する。

### reject の委任上限

同一リポジトリ・同一票に対する初回委任は最大で 3 件まで。`resume` 由来のジョブは数えない。上限到達時の `reject` は終了コード 1 で失敗し、票・履歴・git のいずれも変更しない。

### commit 時の Closes 行の自動付記

ジョブの `meta.json` に `issue: {"repo": "owner/repo", "number": N}` がある場合のみ、コミットメッセージのフッタ（トレーラ群）の最後に `Closes` 行を 1 行足す。メタデータに issue 参照が無い場合は何も足さない。

- **行の形式**: issue の repo とカレント repo の GitHub スラッグ（`origin` リモートの URL から導出）の一致で決める:
  - 一致する: `Closes #N`
  - 一致しない、またはスラッグが導出できない（`origin` が無い・GitHub でない）: `Closes owner/repo#N`
- **重複防止**: ユーザーの `-m` メッセージに既に `Closes #N` または `Closes owner/repo#N` が含まれている場合は追加しない。
- **異なる repo の issue を指す場合の意味**: `Closes owner/repo#N` は、そのコミットが issue のある repo のデフォルトブランチに届いた場合にだけ GitHub が自動で閉じる。それ以外の場合は参照リンクとして働く。subcon のジョブは自分の repo にコミットするので、異なる repo の issue は通常は閉じない（foreman 側で PR を作る際の手がかりになる）。

## 出力の原則

- **標準出力 (stdout)**: 機械可読な JSON のみを出力する。
  - 例外: `diff`（パッチテキスト）、`log`（ログテキスト）、`guide`（Markdown）、`trailer`（1 行テキスト）、`stats --text`（人間向けの集計表）、`export`（JSON Lines。1 行ずつが JSON 値）。
- **標準エラー出力 (stderr)**: 人間向けの進捗ログ、警告、エラーメッセージのみを出力する。
- **配列と単体オブジェクトの原則**:
  - 複数ジョブを同時に扱うことができるコマンド（`submit`, `resume`, `wait`, `list`）は配列を出力する。
    - `submit <ticket>...`: 引数に複数の票を指定できるため、作成結果の配列 `[{...}, ...]` を返す。
    - `resume <id>`: 単一の ID を受け取るが、`submit` と同等のジョブ生成インターフェースとして配列 `[{...}]` を返す。
    - `wait <id>...`: 複数のジョブを同時に待機できるため、各ジョブの結果オブジェクトの配列 `[{...}, ...]` を返す。
    - `list [--all]`: 複数のジョブの一覧を表すため、ジョブ要約の配列 `[{...}, ...]` を返す。
  - 単一ジョブまたは単一操作を扱うコマンド（`run`, `show`, `new`, `apply`, `commit`, `checks`, `reject`, `discard`, `stats`）は単体オブジェクト `{...}` を返す。
- **版 (v) の付与**: ジョブ結果オブジェクト（`show` / `wait` / `run` が返すもの）には `v: 1` が付く。`list` の要約オブジェクトと `stats` の集計オブジェクトには `v` を付けない。

## 終了コード表

複数の終了条件に該当する場合は、**数値が大きい方**の終了コードを採用する。

| コード | 意味 |
| --- | --- |
| 0 | 正常終了。`wait` / `run` では待機した全ジョブが `status: done` かつ `checks.ok: true` |
| 1 | 使い方の誤り・前提条件の不足（引数不正、agy/jq の未検出、票の構文検証失敗、未知のジョブ ID、パッチ適用失敗など） |
| 2 | いずれかのジョブで実装役（バックエンド）が `partial` または `blocked` を申告、または報告なし（`status: null`）で完了 |
| 3 | いずれかのジョブでチェック違反が発生（ worktree 内でのコミット、または `## Files` 範囲外ファイルの変更） |
| 4 | いずれかのジョブが `state: failed`（バックエンドの実行失敗、タイムアウト、ランナーの消失、ジョブ起動失敗など） |
| 5 | `wait` のタイムアウト到達（ジョブが未終了のまま指定時間を超過） |

`show` も同じ規則で単一ジョブの終了コードを返す（実行中・待機中のジョブは 0）。コード 5 は `wait` のタイムアウト時のみ発生する。

### エラーの扱い

- **前提エラー**: コマンドの引数不正、票の検証失敗、必要なツールの欠落など、ジョブ実行前の前提が満たされない場合は、stderr にエラー理由を出力し、非ゼロの終了コード（主に 1）で終了する。このとき stdout は空となる。
- **要素単位のエラー**: `submit` や `resume` で複数ジョブの生成を行う際、個別のジョブ生成で失敗が発生した場合は、stdout の該当要素の `id` を `null` とし、`error` フィールドにエラー文字列を格納する。1 件でも失敗が含まれる場合、コマンド全体の終了コードは 4 となる。

## stats の出力スキーマ

`subcon stats` が出力する集計 JSON の全キーの定義:

- `scope`: 集計範囲（`repo` | `all`）。
- `repo`: 対象リポジトリのパス（`--all` 時は null）。
- `since`: 指定文字列または null。
- `jobs`: 対象ジョブ総数。
- `by_state`: `finished` / `failed` の件数。
- `by_status`: `done` / `partial` / `blocked` / `none` の件数。
- `success`: `state` が finished かつ `status` が done かつチェック合格の件数。
- `success_rate`: `success / jobs`（0.0〜1.0、ジョブ 0 件では null）。
- `applied`: 履歴に `applied` イベントがあるジョブの件数。
- `apply_rate`: 同率・同規則（`applied / jobs`。0.0〜1.0、ジョブ 0 件では null）。
- `duration_s`: `total` と `median`、単位は秒。データがなければ null。
- `tokens`: `input` / `output` / `total` / `cache_read` / `thinking` の合計。
- `by_model`: モデル ID をキーに `jobs` / `success` / `applied` / `tokens_total` を持つオブジェクト。

## 主なオプション

- `--runner R`: ジョブを実行するランナーを指定する（`runners/` 配下のスクリプト名）。既定値は `local`。指定されたランナーが存在しない場合は終了コード 1。
- `--driver D`: 実装役ドライバを指定する（`drivers/` 配下の名前）。`submit` / `run` / `trailer` で使える。`resume` は元ジョブのドライバに固定され、`reject` は元ジョブのドライバで再委任する。既定値は環境変数 `SUBCON_DRIVER` の値、未設定時は `agy`（`trailer` のみ、両方とも未指定ならこのリポジトリの直近ジョブのドライバを使い、ジョブが無ければ `agy`）。`opencode` ドライバも選択でき、モデルは `provider/model` 形式で任意に指定できる（既定はドライバの `default-model`）。`ci` ランナーは `agy` と `claude` に対応する。`ci` で `claude` を使う認証はランナーマシン側で用意する（環境変数 `CLAUDE_CODE_OAUTH_TOKEN`（setup-token）または `ANTHROPIC_API_KEY`。ランナーマシンの `~/.config/subcon/claude-env` に置いてもよい）。`container` ランナーは `agy` と `claude` に対応し、`claude` の場合は環境変数 `ANTHROPIC_API_KEY` が必要（未設定・空なら submit 時に終了コード 1 で失敗する）。
- `--model M`: 選択したドライバに渡すモデル ID を指定する。既定値は環境変数 `SUBCON_MODEL` の値、未設定時はドライバごとの既定モデル（`trailer` でドライバを直近ジョブから引いた場合は、そのジョブのモデル。`--driver` / `SUBCON_DRIVER` を指定した場合は引かない）（`agy`: `gemini-3.8-flash-medium`、`claude`: `claude-haiku-5-5`）。
- `--timeout T`（`submit` / `run` / `resume`）: ドライバに渡すタイムアウト文字列（例: `30m`, `540s`）。既定値は `30m`（`resume` で省略時は再開元ジョブの設定値を引き継ぐ）。
- `--timeout T`（`wait`）: 待機する時間。整数のみ（秒、従来どおり）、または単位付き `<N>s` / `<N>m` / `<N>h`（N は0以上の整数）。既定値は `0`（無期限）。指定時間が経過しても完了していないジョブがある場合、その時点の結果（未終了ジョブは `state: queued` または `running`）を出力して終了コード 5 で終了する（ジョブ自体は停止させない）。不正な値（負数・小数・不明な単位・文字列など）は終了コード 1 で失敗する。
- `--issue <ref>`（`submit` / `run`）: 票の発生元 issue への参照を指定する。受理する形式は `#123`（カレントリポジトリの origin リモートが GitHub の場合）、`owner/repo#123`、および `https://github.com/owner/repo/issues/123`。番号は 1 以上の整数でなければならない。形式不正や origin が取得できない場合はエラーとなり、ジョブは作成されない。`resume` で作られる新ジョブは元ジョブの issue を引き継ぐ。

## 利用者向け環境変数

利用者および上位エージェントが設定可能な環境変数一覧:

- `SUBCON_DRIVER`: 既定で使う実装役ドライバ名（未設定時は `agy`）。`--driver` で上書きできる。
- `SUBCON_MODEL`: 既定で使用するモデル ID（意味は選択中ドライバのモデル ID 空間。未設定時はドライバごとの既定モデル）。
- `SUBCON_CLAUDE_MCP_CONFIG`: `claude` ドライバの MCP 設定の上書き口。未設定時は MCP を無効化する（厳格・空）。`project` のときは claude の既定動作に任せる。それ以外の値は MCP 設定 JSON として渡す。
- `SUBCON_STATE`: subcon の状態ディレクトリのルートパス。ジョブや履歴がここに保存される（未設定時は `${XDG_STATE_HOME:-$HOME/.local/state}/subcon`）。
- `SUBCON_REVIEWER`: コミット時のレビュアー情報（`Name <email>` 形式）。`subcon commit` を実行する際に設定が必須（未設定時は終了コード 1）。
- `SUBCON_COAUTHOR_EMAIL`: `subcon commit` や `subcon trailer` で付与される `Co-Authored-By` のメールアドレス（未設定時は `noreply@google.com`）。
- `SUBCON_NO_AUTH_WARNING`: 設定すると agy の認証方式に関する警告を表示しない。
- `SUBCON_BUDGET_TOKENS`: 今月（UTC）の終了ジョブの `tokens.total` 合計の上限（非負整数）。達していると `submit` / `run` は新しいジョブを作らずに失敗する。未設定または空なら無制限。履歴に記録されたトークン数だけを数えるため、金額の上限ではない。
- `SUBCON_BUDGET_JOBS`: 今月（UTC）の終了ジョブ件数の上限（非負整数）。達していると `submit` / `run` は新しいジョブを作らずに失敗する。未設定または空なら無制限。
- `GEMINI_API_KEY`: subcon 自身は読み取らないが、agy の API キー認証に使われる環境変数で、subcon 経由の実行にも影響する。
- `SUBCON_CONTAINER_ENGINE`: `container` ランナーで使用するコンテナエンジンバイナリ名またはパス（`docker` または `podman`）。未設定時は `docker` → `podman` の順に自動検出される。
- `SUBCON_CONTAINER_IMAGE`: `container` ランナーで使用するコンテナイメージ名（未設定時は `subcon-runner:latest`）。
