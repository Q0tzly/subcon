# 26: ランナー契約のモデル env を SUBCON_JOB_MODEL に分離

## Goal

`SUBCON_MODEL` が「利用者の既定モデル指定」と「ランナーへモデルを渡す契約変数」の二重役割になっているのを解消する。契約側を `SUBCON_JOB_MODEL` に改名し（`SUBCON_JOB_DIR` と接頭辞を揃える）、利用者向けの名前は温存する。公開前にしか安くできない互換切り替え。

## Files

- lib/job.sh
- runners/local
- runners/container
- runners/container-entry.sh
- ci/run-job.sh
- docs/design/v2.md
- docs/design/container-runner.md

## Interface

- ランナー契約としてモデルを渡す env を、全箇所で `SUBCON_MODEL` から `SUBCON_JOB_MODEL` に改名する:
  - lib/job.sh がランナー起動時に export する変数
  - runners/local と runners/container-entry.sh が `--model` の値として読む変数
  - runners/container がコンテナへ渡す（`-e`）変数
  - ci/run-job.sh が `SUBCON_CI_MODEL` から変換して export する変数（コメント内の env 列挙も合わせる）
- 変更しないもの:
  - 利用者向けの `SUBCON_MODEL`（既定モデルの指定。lib/common.sh の `default_model`）。`--model` フラグが優先される従来の解決順もそのまま
  - `SUBCON_CI_MODEL`（runners/ci → ワークフロー → ci/run-job.sh の受け渡し専用の名前）。run-job.sh が SUBCON_JOB_MODEL への変換点になる
  - 過去の作業票（docs/design/v2/04-jobs.md、16-container-runner.md、19-ci-job-script.md など記録としての文書）に出てくる旧名。書き換えない
- 現行の説明だけを実装に合わせる: docs/design/v2.md のランナー契約の env 列挙と、docs/design/container-runner.md の環境変数の説明に出てくる `SUBCON_MODEL` を `SUBCON_JOB_MODEL` に直す

## Acceptance

```sh
./tests/run.sh runnerenv
./tests/run.sh
```

## Notes

- 起点では runnerenv グループ 3 件中 1 件（container の env 境界）が落ちる。残り 2 件は「モデルがランナーまで届くこと」と「利用者ノブが生きていること」の番人で、起点でも通る
- container の受け入れテストは fake engine のログ（`ENV <名前>=<値>`）で境界を観測する。container-entry.sh が読む名前の一致は、境界の内側なのでテストでは観測できない。そちらは差分の目視確認で担保する
