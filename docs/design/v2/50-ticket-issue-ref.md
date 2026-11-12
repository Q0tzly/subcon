# 50-ticket-issue-ref

## Goal

票のメタに発生元 issue への参照を持てるようにする（issue #7、foreman 連携の受け口の前半）。

foreman は issue から票を切る。票と issue の対応がジョブのメタに残れば、後段（票51 の `Closes #N` 自動付記、foreman の Draft PR 生成）がその対応を機械的に辿れる。

## Files

- lib/common.sh
- lib/job.sh
- lib/query.sh
- docs/spec/cli.md
- docs/spec/files.md

## 仕様

### 参照の形式

- メタには `issue: {"repo": "owner/repo", "number": <整数>}` の形で保持する（repo と number を分ける）。
- 指定が無いジョブの meta.json には `issue` キー自体を入れない（`resume_of` と同じ流儀）。

### submit / run の `--issue <ref>`

- `subcon submit` と `subcon run` に `--issue <ref>` オプションを足す。受理する形は3つ:
  - `#123` — repo はカレント repo の origin リモートから導出した GitHub スラッグ（`owner/repo`）。origin が無い・GitHub 形式でない場合はエラー。
  - `owner/repo#123` — そのまま使う。
  - `https://github.com/owner/repo/issues/123` — スラッグと番号を取り出す。
- 番号は1以上の整数。それ以外（形式不明・番号0・文字混じり）はエラーにして、ジョブを作らない。
- 正規化とスラッグ導出は lib/common.sh のヘルパーに置く（後続の票51 でも使う）。
- 複数票を一度に submit する場合は全ジョブに同じ参照が付く。

### resume

- resume で作られる新ジョブは、元ジョブの `issue` をそのまま引き継ぐ。

### 表示

- `subcon show` / `subcon list` の出力（job_result）に `issue` を含める。値の形はメタと同じオブジェクト、無い場合は `null`。

### 仕様書

- docs/spec/cli.md: `submit` / `run` の説明に `--issue` を足す。
- docs/spec/files.md: meta.json のフィールド説明に `issue` を足す。

### 非目標

- 環境変数での指定（`SUBCON_ISSUE` 等）は入れない。
- issue の実在確認（GitHub への問い合わせ）はしない。形式の検証のみ。

## Notes

- 進行状況（2026-11-12）: lib/common.sh のヘルパー（`github_slug`、`issue_ref_json`）は実装済みでコミット `8640115` に着地している。書き直さないこと。残りは lib/job.sh（`--issue` の配線・meta 記録・resume 引継ぎ）、lib/query.sh（表示）、docs/spec/cli.md、docs/spec/files.md。

## Acceptance

- 受け入れテスト（tests/run.sh、監督が先行コミット済み）:
  - `test_submit_issue_shorthand`: origin が GitHub の repo で `--issue "#7"` を付けると、meta の `issue` が `{"repo": "Q0tzly/subcon", "number": 7}` になり、`show` でも見える。
  - `test_submit_issue_full`: `--issue "Q0tzly/other#12"` がそのまま保持される。
  - `test_submit_issue_url`: URL 形式がスラッグと番号に正規化される。
  - `test_submit_issue_invalid`: 不正な参照（`banana`、`#0`、`#abc`）はエラーで、ジョブが作られない。
  - `test_submit_no_issue`: 指定なしでは meta に `issue` キーが無く、`show` の `issue` は `null`。
  - `test_resume_issue_inherited`: `--issue` 付きジョブを resume すると新ジョブも同じ参照を持つ。
- 全テスト合格。
