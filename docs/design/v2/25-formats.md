# 25: ファイル形式の版付けと history 行種別の統一

## Goal

永続ファイル（meta.json / result.json / history.jsonl）に仕様の版 `v: 1` を入れ、history.jsonl の行種別の判定を `.type` に統一する。OSS 公開と仕様の切り出し（フェーズ B）に先立ち、機械が読む永続データの形式を固定する。

## Files

- lib/job.sh
- lib/history.sh
- lib/manage.sh
- docs/design/v2.md

## Interface

- meta.json: ジョブ作成時（新規・resume の両方）の JSON に `"v": 1` を含める
- result.json:
  - 終了時に書く result.json に `"v": 1` を含める
  - 実行中ジョブについて `show` / `wait` が合成する結果（state だけ埋まった形）にも `"v": 1` を含める。形は従来どおりで、v だけが増える
- history.jsonl:
  - finalize 行（`type: "job"`）と event 行（`type: "event"`）の両方に `"v": 1` を含める
- 読み手の互換:
  - `v` の無い既存の meta.json / result.json / history.jsonl を従来どおり読めること。`v` を必須にしない。既存ファイルの移行・書き換えはしない
- 行種別の統一:
  - `subcon reject` の再委任上限の数え（lib/manage.sh）が finalize 行の判定に使っている `(has("event") | not)` を `.type == "job"` に置き換える。stats 側は既に `.type` で判定しており、これで全箇所が `.type` 基準になる
  - type の無い行は finalize 行として数えない（実データの finalize 行は票10以来 `type: "job"` を持つ）
- 報告スキーマ（schema/result.schema.json）には `v` を入れない。あれは agy の出力そのもので、版は包む側（result.json）で持つ
- docs/design/v2.md の現行記述を実装に合わせる:
  - ジョブ保存の meta.json の説明に `v` を追加
  - 結果（result.json）の例の先頭に `"v": 1` を追加
  - 使用統計の記録の説明に、finalize 行が `{type: "job", v: 1, ...}`、event 行が `{type: "event", v: 1, id, event, at}` である現行の形を明記する

## Acceptance

```sh
./tests/run.sh formats
./tests/run.sh
```

## Notes

- 起点では formats グループ 5 件中 4 件が落ちる（v がどこにも無いため）。残り 1 件（v 無しの既存ファイルが読めること）は後方互換の番人で、起点でも通る
- reject の上限数えの変更は、既存の test_reject_cap（実委任 3 回で打ち止め）がそのまま番人になる
