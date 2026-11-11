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
   - 各パスは空文字でなく、前後のバッククォート（`` ` ``）や空白は除去されて解釈される。
   - 各パスはリポジトリのルートからの相対パスでなければならない（`/` で始まってはならない）。
   - 各パスは要素として `.` や `..` を含んではならない（例: `foo/../bar` や `./baz` は不可）。
   - 各パスはワイルドカード・glob 文字（`*`, `?`, `[`）を含んではならない。

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
- `model`: 使用したモデル ID（文字列、例: `"gemini-3.8-flash-medium"`）。
- `timeout`: ジョブに指定されたタイムアウト時間（文字列、例: `"30m"`）。
- `created_at`: ジョブの作成時刻（ISO 8601 UTC 文字列）。

### resume 時の追加フィールド

`subcon resume` によって作成されたジョブの場合、上記に加えて以下の 2 フィールドが追加される:

- `resume_of`: 再開元のジョブ ID（文字列）。
- `conversation`: 再開対象となった agy の会話 ID（`conversation_id`、文字列）。

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
  "conversation": "c4d3b2a1-..."
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
  - `files_changed`: git diff から検出された、実際に変更された全ファイルの配列（文字列配列）。
- `report`: agy 出力の `structured_output`（オブジェクト、無ければ `null`）。
- `patch`: 生成されたパッチファイルの絶対パス（文字列、パッチが無ければ `null`）。
- `diffstat`: パッチの統計文字列（文字列。変更ゼロ行のパッチの場合は空文字列 `""`、パッチ自体が無ければ `null`）。
- `error`: ジョブ失敗時のエラー理由（文字列、正常終了時は `null`）。
- `agy_error`: agy が出力したエラー情報（文字列または JSON 文字列、無ければ `null`）。
- `conversation`: agy が出力した会話 ID（文字列、無ければ `null`）。再開（`resume`）時に使用される。

### 実行中ジョブの規則

ジョブが実行中（`state` が `"queued"` または `"running"`）に `subcon show` や `subcon wait`（タイムアウト時）によって参照された場合、`v`, `id`, `repo`, `ticket`, `state` のみが設定され、それ以外のすべてのフィールドは `null` となる。

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
  "ticket": "docs/design/feat/01-parser.md",
  "model": "gemini-3.8-flash-medium",
  "runner": "local",
  "created_at": "2026-11-11T09:00:00Z",
  "finished_at": "2026-11-11T09:05:00Z",
  "duration_s": 300.5,
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
- `finished_at`: ジョブ終了時刻（ISO 8601 UTC 文字列）。
- `duration_s`: agy 出力の `duration_seconds`（数値、無ければ `null`）。
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
