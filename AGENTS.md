# subcon

上位エージェントが作業票を Gemini Flash（agy）に委任し、パッチを検収するための CLI。bash 製。

- 設計: `docs/design/v2.md`（v2.1 の resume と v2.2 の stats は実装済み。未実装は container / remote ランナー。ベンチマーク計画は `docs/design/benchmark.md`）
- 作業票の一覧と次にやる票: `docs/design/v2/00-plan.md`
- 委任のルール: `docs/delegation.md`（`bin/subcon guide` でも表示）。この repo の開発もこの流れで進める
- テスト: `tests/run.sh [グループ...]`。本物の agy は使わない。成否は終了コードで判定する
- macOS の `/bin/bash` 3.2 で動かす。連想配列・`mapfile`・`${x,,}` は使わず、`set -u` 下で空配列を `"${a[@]}"` と展開しない
- `bin/subcon` はサブコマンドの振り分けだけ。中身は `lib/` に票ごとに分かれている
