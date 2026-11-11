# 32-readme-launch

## Goal

OSS 公開（フェーズ A）に向けて README を最終形に寄せる。現状の README には CI ランナーの説明が無く、使い方も新コマンド（log / commit / reject）に追いついていない。公開時の第一印象として、実行ルートの全体像と規約上の前提が README だけで分かるようにする。

## Files

- README.md

## Interface

1. **CI ランナーの節を追加する**（container ランナーの節の直後）。内容:
   - 概要: GitHub Actions の self-hosted ランナー上で票を実行するリモートランナー。実行と agy の認証は利用者自身のマシンに留まる。
   - 使い方: `.github/workflows/subcon-job.yml` を自分のリポジトリに置き、ラベル `subcon` の self-hosted ランナーを登録したうえで `subcon submit --runner ci <ticket>`。
   - 設計と仕様へのリンク: `docs/design/ci-runner.md` と `docs/spec/runner.md`。
2. **実行ルートの 2 段構えを明記する**（CI ランナーの節の中、または独立した短い箇条書き）:
   - self-hosted（自分のマシンで Actions を回す）: 消費者サブスクリプションのログインで運用できる本命ルート。自分の CI／スクリプトから agy を呼ぶ形は、公式に意図された使い方とされている。
   - GitHub ホスト型ランナー: API キー方式が必須で、有料ティアが前提（無料枠は 5 リクエスト/分で、エージェント実行には不足する）。
3. **使い方の補完**:
   - 使い方のコードブロックに `subcon log <id>                   # ジョブのログを見る` を `subcon diff` の直後へ追加する。
   - 「ほかに」の列挙に `commit`（検収した変更を trailer 付きでコミットする）と `reject`（理由を票に記録して差し戻し、再委任する）を追加する。
4. 「現状の制約」の文面は維持する（削らない、大きく書き換えない）。
5. ライセンス節は追加しない（監督側が LICENSE と合わせて後から足す）。英語化もしない。

## Acceptance

- [ ] `grep -q -- '--runner ci' README.md`
- [ ] `grep -q 'subcon-job.yml' README.md`
- [ ] `grep -q '有料ティア' README.md`
- [ ] `grep -q 'subcon log' README.md`
- [ ] `grep -q 'subcon commit' README.md`
- [ ] `grep -q 'subcon reject' README.md`
- [ ] `./tests/run.sh`

## Notes

- README は公開文書である。戦略・価格・収益化の話は書かない（それらは非公開の決定事項）。
- 規約まわりの表現は「現状の制約」節の既存文面のトーンに揃え、断定しすぎない（「認められておらず」「なりうる」程度）。
