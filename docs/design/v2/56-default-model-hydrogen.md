# 56-default-model-hydrogen

## Goal

agy ドライバの既定モデルを `gemini-3.8-flash-medium` から `gemini-4-hydrogen-medium` に切り替える（issue #1 の判断）。

根拠: GrusArch の安全設計での同一票 A/B 実測（2026-11-13）で、Hydrogen は Flash の約 1/4.2 のトークンで同等の品質だった。ドライバ自体（agy）は変更しない。

## Files

- drivers/agy
- README.md
- docs/delegation.md
- docs/spec/cli.md
- docs/design/driver-layer.md
- docs/design/v2.md

## 仕様

- `drivers/agy` の `default-model` が `gemini-4-hydrogen-medium` を返す。
- 現行ドキュメント側の「既定モデル」の記述を追従させる:
  - README.md: ドライバ紹介の既定モデル表記。
  - docs/delegation.md: 既定モデルの行。あわせて「量が多い・難しめの票」の推奨も `gemini-4-hydrogen-high` にする。
  - docs/spec/cli.md: `--model` の説明にある agy の既定モデル表記。
  - docs/design/driver-layer.md / docs/design/v2.md: 既定モデルの記述箇所のみ（実機検証の記録など、当時のモデル名を記した歴史的記述は書き換えない）。
- ジョブの記録・履歴・stats の形式は変えない（モデル名は文字列として既に記録されている）。

## Acceptance

- 受け入れテスト（tests/run.sh、監督が先行コミット済み）: 既定ジョブの meta.model と履歴行の model が `gemini-4-hydrogen-medium` になる（従来の既定値アサーションを新既定に更新済み）。
- 全テスト合格。
