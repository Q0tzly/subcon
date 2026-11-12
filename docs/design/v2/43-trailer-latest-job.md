# 43-trailer-latest-job

## Goal

`subcon trailer` が `--driver` も `SUBCON_DRIVER` も指定されていないとき、既定の agy ではなく **このリポジトリの直近ジョブの driver / model** を使うようにする。

背景: trailer はコミット時の Co-Authored-By 生成に使うが、現行はドライバ省略時に常に agy を引く。claude や opencode のジョブを検収してコミットする際、`--driver` の付け忘れで帰属が Gemini になってしまう（票42 の受け入れテスト作成時に監督側でも実際に踏んだ）。

## Files

- lib/common.sh
- docs/spec/cli.md

## 仕様

対象は `cmd_trailer`（lib/common.sh）のドライバ／モデルの解決順のみ:

1. ドライバの優先順位: `--driver` フラグ > `SUBCON_DRIVER` 環境変数 > このリポジトリの直近ジョブの `meta.json` の `driver`（無い場合は `agy` として扱う） > `agy`。
2. モデルの優先順位: `--model` フラグ > （ドライバが直近ジョブ由来のとき）そのジョブの `meta.json` の `model` > `default_model(driver)`。
   - `--driver` を明示した場合は、ジョブの model は引かない（現行どおりドライバの既定モデル）。
3. 「直近ジョブ」は `$SUBCON_STATE/jobs/` 以下のジョブのうち、`meta.json` の `repo` が現在のリポジトリ（`repo_top`）と一致するものの中で、ジョブ ID（時刻順ソート可能）が最大のもの。他リポジトリのジョブは無視する。該当ジョブが無い・meta が読めない場合は現行の既定（agy）に落ちる。
4. `subcon commit` 側の trailer 生成（ジョブ自身の meta を使う経路）は変更しない。

## Acceptance

- 受け入れテスト（tests/run.sh、監督が先行コミット済み）:
  - `test_driver_trailer_latest_job`: fakeok のジョブを run した後の素の `trailer` が Fake Model One を返し、その後 agy のジョブを run すると Gemini に切り替わる。`SUBCON_DRIVER` を指定するとジョブ由来より優先される。
  - `test_driver_trailer_latest_job_other_repo`: 他リポジトリのジョブ（新しい ID）しか無い場合は従来どおり agy 既定に落ちる。
- 全テスト合格。
