# 53-checks-recompute

## Goal

ジョブの checks を後から再計算できる `subcon checks <id>` を追加する（issue #9）。

checks は finalize 時に、提出時点の票コピー（ジョブディレクトリ内の `ticket.md`）から計算されて固定される。票側のタイプミス（`## Files` のパスに注釈が空白なしでくっつく等）で正当な実装が `ok: false` になると、`subcon commit` がブロックされ、票を直しても回復手段が無い（票49 で実際に踏んだ）。

## Files

- bin/subcon （`checks` の dispatch と Usage への追加）
- lib/manage.sh
- docs/spec/cli.md
- docs/spec/files.md

## 仕様

### `subcon checks <id>`

- 終了済みジョブ（state が `finished` または `failed`）に対して、checks を再計算して result.json を更新し、新しい checks オブジェクトを標準出力に出す。
- 実行中（`queued` / `running`）のジョブと、存在しない id はエラー（終了コード1）。
- 再計算の入力:
  - `files_changed`: ジョブの `patch.diff` に現れるファイルの一覧（finalize 時と同じ集合になること）。
  - 許可リスト: **現在の** repo にある票ファイル（meta.json の `ticket` が指す、作業ツリー上の現行内容）の `## Files`。
  - `committed`: 保存されている値をそのまま引き継ぐ（再計算では導出しない）。
  - `ok` / `outside_files` は finalize と同じ規則で導出する。
- 監査可能性: 更新後の checks に `recomputed_at`（ISO 8601 UTC）を付け、更新前の checks オブジェクト全体を `previous_checks` として保持する。再計算を繰り返した場合は、その時点の checks が次の `previous_checks` になる（履歴は1代だけ保持）。
- カレント repo がジョブの repo と異なる場合はエラー（`commit` と同じ作法）。

### 仕様書

- docs/spec/cli.md: コマンド一覧に `checks` を足す。
- docs/spec/files.md: result.json の checks に `recomputed_at` / `previous_checks` が付きうることを書く。

## Acceptance

- 受け入れテスト（tests/run.sh、監督が先行コミット済み）:
  - `test_checks_recompute_after_ticket_fix`: 票の Files に無いファイルを変更したジョブ（checks が false）について、repo 側の票を直してから `subcon checks` を実行すると `ok: true` になり、`recomputed_at` と `previous_checks`（旧 outside_files を含む）が記録され、その後 `apply` → `commit` が通る。
  - `test_checks_recompute_still_outside`: 票を直さなければ再計算後も `ok: false` のままで、`previous_checks` が記録される。
  - `test_checks_unknown`: 存在しない id はエラー。
  - `test_checks_running`: 実行中ジョブはエラー。
- 全テスト合格。
