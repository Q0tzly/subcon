# 54-export-identity

## Goal

export 形式に跨機械の識別キーを入れる（issue #11、設計判断は issue のコメントで確定済み）。

- エンベロープに `source`（state root の不透明 ID）を足し、重複除去キー `(source, id)` を規定する。
- ジョブ行に `repo_slug` を足す（finalize 時に記録）。

どちらも追加的変更で、版は上げない（エンベロープ・行とも `v: 1` のまま）。

## Files

- lib/export.sh
- lib/history.sh
- docs/spec/files.md

## 仕様

### source

- 値: 128bit 乱数の hex 32 文字（例: `/dev/urandom` から 16 バイトを hex 化）。
- 保存: state root 直下の `source` ファイル（`$(state_root)/source`）に値だけを書く。
- 生成: `subcon export` の実行時に、ファイルが無ければ（または空なら）生成して保存する。以後の export では保存値を使う。ジョブ記録時には生成しない。
- エンベロープには常に文字列として出す（null にしない）。

### repo_slug

- 履歴行を書く処理（`history_append_job`）で、`repo_slug` をジョブ行に追加する。値は repo（`meta.repo`）に対する `github_slug` の結果、引けなければ `null`。
- export は従来どおり履歴行をそのまま出す（export 時の引き直し・補完はしない）。過去の履歴行には `repo_slug` 自体が無いままになる。

### 仕様書（docs/spec/files.md）

- エクスポート形式の節に `source` の説明（生成・保存・再生成の方法）を足す。
- 重複除去キーが `(source, id)` であること、repo の集約キーは `repo_slug`（null の場合は `(source, repo)`）であることを書く。
- event 行は export しないことが v1 の非目標である旨を明記する（既に「出力しない」とは書いてあるので、非目標としての位置づけを補う）。
- `cost_usd: null` は「価格なし」を意味し 0 ではないこと、`created_at` / `finished_at` は各マシンのローカル時計で、順序は source 単位で見ることを注記する。
- history.jsonl の節に `repo_slug` フィールドの説明を足す。

## Acceptance

- 受け入れテスト（tests/run.sh、監督が先行コミット済み）:
  - `test_export_source`: 2回の export でエンベロープの `source` が同一で、hex 32 文字の形式であり、`source` ファイルの内容と一致する。
  - `test_export_source_regenerated`: `source` ファイルを消すと、次の export で別の `source` が生成される。
  - `test_history_repo_slug`: origin の無い repo のジョブ行は `repo_slug: null`、GitHub の origin を足した後のジョブ行はその slug になる。
- 全テスト合格。
