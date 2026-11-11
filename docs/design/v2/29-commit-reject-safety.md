# 29: commit / reject の事前検証と安全化

## Goal

Argon の仕様レビューで見つかった副作用の順序の問題を直す: `commit` と `reject` が、agy の解決やランナーの検証をしないまま、ステージング・票の書き換え・コミットといった巻き戻せない副作用を先に起こしてから失敗する。あわせて `commit` に「パッチが当たっているか」と「二重コミット」のガードを入れ、reject の再委任上限の数えを委任回数だけに揃える。

## Files

- lib/manage.sh

## Interface

`subcon commit`:

- 副作用（ステージング、コミット）の前に、失敗しうる確認をすべて済ませる:
  - `require_agy` を早い段階で呼ぶ（agy が無ければ、インデックスを汚さず終了コード 1）
  - 実装者の表示名（`model_name`）の解決もステージングより前に行い、失敗したら何も変えずに終わる
- 二重コミットのガード: history.jsonl にそのジョブの `committed` イベントが既にあれば、終了コード 1 で拒否する（stderr に `already committed` を含む）
- 当たっているかのガード（`--edited` が無い場合のみ）: ジョブの patch.diff が存在し、`git apply --check --reverse` が今の作業ツリーに対して成功すること。失敗したら終了コード 1 で拒否する（stderr に `not applied` を含む）。`--edited` の場合はこの確認をしない（上位が差分に責任を持つ従来の運用）
- 上記の確認はすべてステージングより前に行う。従来の正常系の挙動（trailer、history 記録、出力 JSON）は変えない

`subcon reject`:

- `require_agy` を、票の書き換えを含むあらゆる変更より前に呼ぶ
- 実効ランナー（`--runner` 指定があればそれ、無ければ元のジョブの runner）の検証を、票の書き換え・コミット・history 記録より前に済ませる:
  - ランナーの実行ファイルが存在すること（submit と同じ解決方法で確認する）
  - container なら `require_container`、ci なら `require_ci` の事前確認もこの時点で済ませる
  - 検証に失敗したら終了コード 1 で、票ファイル・git 履歴・history.jsonl のどれも変えずに終わる
- 再委任上限の数えを「委任の回数」に揃える: history.jsonl の finalize 行のうち `resume_of` が無い（null か欠落）行だけを数える。resume で作られたジョブは上限を消費しない。コード内のコメントも実装に合わせる

## Acceptance

```sh
./tests/run.sh guard
./tests/run.sh
```

## Notes

- 起点では guard グループ 7 件中 6 件が落ちる（--edited で追加編集を許す件だけが番人として通る）
- commit の逆適用チェックは「パッチの後像と作業ツリーが一致するか」の確認であり、上位が apply 後にファイルをさらに編集した場合は（--edited なしでは）拒否されるのが意図した挙動
