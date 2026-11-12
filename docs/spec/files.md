仕様の版: 1

この文書は subcon が扱うファイル形式およびデータ永続化に関する現行仕様の正本である。

# ファイル形式仕様

## 作業票（チケット）フォーマット

作業票は Markdown 形式（`.md`）で記述される。

### パーサによる構文検証（強制仕様）

`subcon submit` による票の検証（`ticket_validate`）において、パーサが機械的に存在と妥当性を強制するのは **`## Files` 節のみ** である。

1. **ファイル自体の要件**:
   - リポジトリ内に存在すること。
   - `HEAD` にコミット済みであること。
   - 作業ツリーに未コミットの変更が存在しないこと（コミット内容と一致していること）。
2. **`## Files` 節の要件**:
   - 見出し行 `## Files` が存在すること。
   - 見出し直下にリスト形式（`- <path>` または `* <path>`）で 1 件以上のパスが指定されていること。
   - 各エントリは最初の空白で切り捨てられ、空白以降の文字列は注記として無視される。したがってパス自体に空白文字は使えない。バッククォートは除去される。
   - 各パスはリポジトリのルートからの相対パスでなければならない（`/` で始まってはならない）。
   - 各パスは要素として `.` や `..` を含んではならない（例: `foo/../bar` や `./baz` は不可）。
   - 各パスはワイルドカード・glob 文字（`*`, `?`, `[`）を含んではならない。
   - 節は `## ` で始まる次の見出しで終わるが、`### ` 等の下位見出しでは終わらない（リスト行でない行は無視される）。
   - パーサは各パスの存在やファイル／ディレクトリの別を検証しない（構文のみ）。範囲チェックは変更されたファイルのパスとの完全一致で行われるため、ディレクトリを指定しても配下のファイルは許可範囲にならない。ファイルの完全な相対パスを列挙すること。

### 慣習としての節（非強制仕様）

`docs/delegation.md` で推奨される以下の節は、人間および上位エージェントとバックエンド間の協調のための慣習であり、subcon のパーサによる構文上の強制は行われない:

- `## Goal`: 実装の目的（1〜3 文）。
- `## Interface`: 公開する型、関数シグネチャ、CLI 引数、設定形式など。
- `## Acceptance`: 検証のために実行するコマンドリスト。
- `## Notes`: 前提、注意事項、制約など。差し戻し（`reject`）時にはここに差し戻し理由が追記される。

## meta.json

ジョブのメタデータを保持するファイル。ジョブ作成時に `${SUBCON_STATE}/jobs/<id>/meta.json` にアトミックに書き込まれる。

### フィールド一覧

```json
{
  "v": 1,
  "id": "20261111-180000-01-parser-a1b2",
  "repo": "/path/to/repo",
  "ticket": "docs/design/feat/01-parser.md",
  "base": "0123456789abcdef0123456789abcdef01234567",
  "runner": "local",
  "driver": "agy",
  "model": "gemini-3.8-flash-medium",
  "timeout": "30m",
  "created_at": "2026-11-11T09:00:00Z"
}
```

- `v`: フォーマットのバージョン番号（整数: `1`）。
- `id`: ジョブの一意識別子（文字列）。形式は `<YYYYmmdd-HHMMSS>-<票名>-<4桁hex>`。
- `repo`: 対象リポジトリのルートディレクトリの絶対パス（文字列）。
- `ticket`: リポジトリルートからの票ファイルの相対パス（文字列）。
- `base`: ジョブ開始時のベースコミットハッシュ（`HEAD` の SHA-1、文字列）。
- `runner`: 使用したランナー名（文字列、例: `"local"`, `"container"`, `"ci"`）。
- `driver`: 使用したドライバ名（文字列、例: `"agy"`, `"claude"`）。
- `model`: 使用したモデル ID（文字列、例: `"gemini-3.8-flash-medium"`）。
- `timeout`: ジョブに指定されたタイムアウト時間（文字列、例: `"30m"`）。
- `created_at`: ジョブの作成時刻（ISO 8601 UTC 文字列）。
- `issue`: 発生元 issue の参照オブジェクト（`{"repo": "owner/repo", "number": <整数>}`）。`--issue` で指定された場合、または `resume` で元ジョブから引き継がれた場合にのみ存在し、指定がないジョブの `meta.json` にはキー自体が存在しない。

### resume 時の追加フィールド

`subcon resume` によって作成されたジョブの場合、上記に加えて以下の 2 フィールドが追加される:

- `resume_of`: 再開元のジョブ ID（文字列）。
- `conversation`: 再開対象となったドライバの会話 ID（`conversation_id`、文字列）。

## result.json

ジョブの実行結果を保持するファイル。ジョブ完了時（`finished` または `failed`）に `${SUBCON_STATE}/jobs/<id>/result.json` に書き込まれる。

### フィールド一覧と例

```json
{
  "v": 1,
  "id": "20261111-180000-01-parser-a1b2",
  "repo": "/path/to/repo",
  "ticket": "docs/design/feat/01-parser.md",
  "state": "finished",
  "status": "done",
  "checks": {
    "ok": true,
    "committed": false,
    "outside_files": [],
    "files_changed": [
      "src/parser.rs"
    ]
  },
  "report": {
    "status": "done",
    "summary": "Implemented parser",
    "files_changed": ["src/parser.rs"],
    "commands_run": [
      {
        "command": "cargo test",
        "exit_code": 0
      }
    ],
    "design_questions": [],
    "issues_found": []
  },
  "patch": "/path/to/state/subcon/jobs/20261111-180000-01-parser-a1b2/patch.diff",
  "diffstat": "1 file changed, 20 insertions(+)",
  "error": null,
  "agy_error": null,
  "conversation": "c4d3b2a1-...",
  "issue": {
    "repo": "owner/repo",
    "number": 123
  }
}
```

- `v`: フォーマットのバージョン番号（整数: `1`）。
- `id`: ジョブ ID（文字列）。
- `repo`: 対象リポジトリの絶対パス（文字列）。
- `ticket`: 票の相対パス（文字列）。
- `state`: 実行状態（文字列: `"queued"`, `"running"`, `"finished"`, `"failed"`）。
- `status`: バックエンド（Flash）の自己申告（文字列: `"done"`, `"partial"`, `"blocked"`、または `null`）。
- `checks`: 自動検査結果のオブジェクト。パッチが生成された場合のみ設定され、パッチが存在しない場合は `null`。
  - `ok`: `committed` が false かつ `outside_files` が空配列である場合に `true`（真偽値）。
  - `committed`: ジョブの作業ツリーでコミットが行われ、`HEAD` が `base` から進んでいる場合に `true`（真偽値）。
  - `outside_files`: 票の `## Files` に記載されていない変更ファイルの配列（文字列配列）。
  - `files_changed`: git diff から検出された、実際に変更された全ファイルの配列（文字列配列）。ビルドツール等の生成ファイル（例: `Cargo.lock`）も `files_changed` に含まれるため、`## Files` に無い生成物が生じるとチェック違反（範囲外変更）になる。生成物が予見される票では `## Files` に含めること。
  - `recomputed_at`: `subcon checks` による再計算が行われた時刻（ISO 8601 UTC 文字列、再計算されていない場合はキー自体が存在しない）。
  - `previous_checks`: 再計算直前の checks オブジェクト全体（オブジェクト、再計算されていない場合はキー自体が存在しない。再計算が繰り返された場合は直前の checks のみが保持され、履歴は1代限り）。
- `report`: agy 出力の `structured_output`（オブジェクト、無ければ `null`）。
- `patch`: 生成されたパッチファイルの絶対パス（文字列、パッチが無ければ `null`）。
- `diffstat`: パッチの統計文字列（文字列。変更ゼロ行のパッチの場合は空文字列 `""`、パッチ自体が無ければ `null`）。
- `error`: ジョブ失敗時のエラー理由（文字列、正常終了時は `null`）。
- `agy_error`: agy が出力したエラー情報（文字列または JSON 文字列、無ければ `null`）。
- `conversation`: agy が出力した会話 ID（文字列、無ければ `null`）。再開（`resume`）時に使用される。
- `issue`: 発生元 issue の参照オブジェクト（`{"repo": "owner/repo", "number": <整数>}`）、または `null`。

### 実行中ジョブの規則

ジョブが実行中（`state` が `"queued"` または `"running"`）に `subcon show` や `subcon wait`（タイムアウト時）によって参照された場合、`v`, `id`, `repo`, `ticket`, `state` のほか、`issue`（meta に記録されたオブジェクト、無ければ `null`）が設定され、それ以外のすべてのフィールドは `null` となる。

## history.jsonl

利用統計・委任履歴を記録する追記専用ファイル（JSON Lines 形式）。`${SUBCON_STATE}/history.jsonl` に保存され、ジョブが `discard` されても保持される。

### 行種別の判定原則

行種別は必ず `.type` フィールドの値によって判定しなければならない。

- `type == "job"`: ジョブ完了時の finalize 行。
- `type == "event"`: ジョブに対する操作（apply, commit, reject 等）の event 行。

旧バージョンで記録された `v` フィールドを持たない行についても、後方互換性をもって読み込み可能でなければならない。

### finalize 行 (`type: "job"`)

ジョブ終了時（`job_finalize`）に書き込まれる。

```json
{
  "type": "job",
  "v": 1,
  "id": "20261111-180000-01-parser-a1b2",
  "repo": "/path/to/repo",
  "repo_slug": "owner/repo",
  "ticket": "docs/design/feat/01-parser.md",
  "model": "gemini-3.8-flash-medium",
  "runner": "local",
  "driver": "agy",
  "created_at": "2026-11-11T09:00:00Z",
  "finished_at": "2026-11-11T09:05:00Z",
  "duration_s": 300.5,
  "cost_usd": 0.42,
  "state": "finished",
  "status": "done",
  "checks_ok": true,
  "files_changed": 1,
  "insertions": 20,
  "deletions": 0,
  "tokens": {
    "input": 12000,
    "output": 1500,
    "total": 13500,
    "cache_read": 8000,
    "thinking": 200
  },
  "resume_of": null
}
```

- `type`: 固定値 `"job"`。
- `v`: フォーマットのバージョン番号（整数: `1`）。
- `id`, `repo`, `ticket`, `model`, `runner`, `created_at`, `state`, `status`: ジョブ情報。
- `repo_slug`: 対象リポジトリ（`repo`）の origin リモートに対する `github_slug` の値（文字列、例: `"owner/repo"`。origin が GitHub URL でない場合や取得できない場合は `null`）。過去の履歴行にはキー自体が存在しない場合がある。
- `driver`: 実行したドライバ名（`meta.json` の `driver` を写す。ドライバ記録の無い旧ジョブは `"agy"` として記録される）。
- `finished_at`: ジョブ終了時刻（ISO 8601 UTC 文字列）。
- `duration_s`: agy 出力の `duration_seconds`（数値、無ければ `null`）。
- `cost_usd`: agy 出力の `cost_usd`（数値、無ければ `null`）。価格表による推定は行わない。`null` のジョブは stats で unpriced として件数のみ集計される。
- `checks_ok`: `checks.ok` の値（真偽値、チェックが無ければ `null`）。
- `files_changed`: 変更ファイル数（数値、無ければ `null`）。
- `insertions`: パッチの追加行数（数値、パッチが無ければ `null`、変更なしなら `0`）。
- `deletions`: パッチの削除行数（数値、パッチが無ければ `null`、変更なしなら `0`）。
- `tokens`: トークン使用統計オブジェクト（`input`, `output`, `total`, `cache_read`, `thinking` 各キーを持つ。agy の `usage` が無ければ `null`）。
- `resume_of`: 再開元ジョブの ID（再開ジョブでない場合は `null`）。

### event 行 (`type: "event"`)

ジョブのパッチ適用やコミットなどのイベント発生時に書き込まれる。

```json
{
  "type": "event",
  "v": 1,
  "id": "20261111-180000-01-parser-a1b2",
  "event": "applied",
  "at": "2026-11-11T09:10:00Z"
}
```

- `type`: 固定値 `"event"`。
- `v`: フォーマットのバージョン番号（整数: `1`）。
- `id`: 対象ジョブの ID。
- `event`: イベント種別（文字列: `"applied"`, `"committed"`, `"rejected"`）。
- `at`: イベント発生時刻（ISO 8601 UTC 文字列）。

## state ファイルと patch.diff の位置づけ

### state ファイル

ジョブディレクトリ直下（`${SUBCON_STATE}/jobs/<id>/state`）に置かれる単一単語のテキストファイル。

- ジョブの現在状態を示す（`queued` / `running` / `finished` / `failed` のいずれか 1 単語＋末尾改行）。
- 状態遷移は `queued` → `running` → `finished` または `failed` の単方向不可逆である。
- 読み取り中の競合や破損を防ぐため、一時ファイルへの書き込みと `mv`（アトミックな置き換え）によって更新される。

### patch.diff

ジョブディレクトリ直下（`${SUBCON_STATE}/jobs/<id>/patch.diff`）に置かれる Unified diff 形式のパッチファイル。

- ジョブ完了時に作業ツリーの変更全体（未追跡ファイル・新規ファイル・バイナリ変更を含む）を `git -C work add -A` でステージングし、`git -C work diff --cached --binary <base>` によって抽出される。
- ジョブ内の作業でコミット（`git commit`）が行われていた場合でも、`base` コミットからの差分として生成されるため、加えられた変更が失われることはない。
- 差分がゼロ件の場合は空ファイルとして生成される。
- パッチ生成処理自体が失敗した場合、ファイルは作成されない（存在しない）。

## エクスポート形式（`subcon export`）

`subcon export` は履歴（`history.jsonl`）のメタデータを JSON Lines（1 行 1 JSON 値）で標準出力に出す。外部（コントロールプレーン等）へ渡す形式であり、集計済みサマリ（`stats`）ではなくジョブ行そのものを流す。機械・repo を跨いだ集計はサマリ同士では再構成できないため、レコード形式を正とする。

### エンベロープ（先頭 1 行）

```json
{"type":"export","v":1,"source":"0123456789abcdef0123456789abcdef","exported_at":"2026-11-12T09:00:00Z","scope":"repo","repo":"/path/to/repo"}
```

- `type`: 固定値 `"export"`。
- `v`: エクスポート形式の版（整数: `1`）。これはエクスポート形式そのものの版であり、個々の行（ジョブ行の `v` を含む）の版とは独立している。形式に破壊的変更が入ったときに上げる。
- `source`: state root（`${SUBCON_STATE}`）の不透明 ID（文字列、128bit 乱数の hex 32 文字）。常に文字列として出力され、`null` にはならない。
- `exported_at`: 出力時刻（ISO 8601 UTC 文字列）。
- `scope`: 対象範囲（`repo` | `all`）。`--all` 指定時は `all`。
- `repo`: 対象リポジトリの絶対パス（文字列）。`scope` が `all` の場合は `null`。

#### source の生成と保存

- 値: 128bit 乱数の hex 32 文字（例: `/dev/urandom` から 16 バイトを hex 化）。
- 保存: state root 直下の `source` ファイル（`${SUBCON_STATE}/source`）に値だけを書く。
- 生成: `subcon export` の実行時に、ファイルが存在しないか空の場合に生成して保存する。以後の export では保存値を使う。ジョブ記録時には生成しない。
- 再生成: 手動等で `source` ファイルを削除すると、次回の export 時に新しい `source` が再生成される。

### ジョブ行（2 行目以降）

- 履歴の `type == "job"` の行を、そのまま出す（整形はしない）。ジョブ行は「finalize 行」（`history.jsonl` のジョブ行）と同一であり、フィールドの意味は本書の `history.jsonl` の節に従う。
- `type == "event"` の行は出力しない（event 行のエクスポートは v1 の非目標である。ジョブ単位のメトリクス集約に集中し、操作ログの集約は対象外とする）。
- 対象範囲は `subcon stats` と同じ。既定は現在のリポジトリのジョブのみ、`--all` で全リポジトリ。`--since <N>d|<N>h` は `created_at` が cutoff 以降のジョブに絞る。

### 跨機械での集約・重複除去仕様

外部集約系（コントロールプレーン等）で複数マシンのエクスポートを集約する際の規約は以下のとおり:

- **重複除去キー**: `(source, id)`。異なるマシン間や state root 間で同一 ID が衝突する可能性を排除し、レコードを一意に識別する。
- **リポジトリ集約キー**: `repo_slug`。`repo_slug` が `null` のリポジトリは `(source, repo)` を集約キーとする。
- **`cost_usd: null` の解釈**: `cost_usd: null` は「価格なし（未評価）」を意味し、コスト 0（`0`）とは異なる（stats 集計でも unpriced として扱われる）。
- **時刻と順序**: `created_at` / `finished_at` は各マシンのローカル時計（UTC）で記録されるため、異なるマシン間を跨いだ厳密な時系列比較は保証されない。順序は `source` 単位で見ることを前提とする。

### 履歴が無い場合

`history.jsonl` が存在しなければ、エンベロープ 1 行のみを出力して正常終了する。
