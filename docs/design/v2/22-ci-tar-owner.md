# CI ランナーの tar 所有者問題を直す

## Goal
実ワークフローの煙テスト（2026-11-11、Mac mini）で判明した不具合を直す。CI 側（macOS、uid 501）が作った `work.tar.gz` をホストで展開するとき、tar が所有者を復元しようとして失敗し（`Cannot change ownership to uid 501`）、`runners/ci` が終了コード 2 で落ちる。成功したジョブでも失敗扱いになり、`agy.json` のコピーまで届かない。

## Files
- runners/ci

## Interface
`runners/ci` の artifact 展開で、所有者を復元しない形に変える:

- `work.tar.gz` の展開に `--no-same-owner` を付ける（GNU tar / bsdtar 両対応のフラグ）。展開先の所有者は展開したユーザーのものになるのが正しい
- これ以外の挙動（dispatch・ポーリング・締め切り・cancel・終了コード）は変えない

合格テストは上位が先に書いてコミット済み（`tests/fake-gh` に、artifact の `work.tar.gz` を uid 501 / gid 50 で詰め直すモード `FAKE_GH_FOREIGN_OWNER` を追加し、`tests/run.sh` の cirunner グループに `test_cirunner_foreign_owner` を追加。このテストは、chown が拒否されるファイルシステム上（本番の状態ディレクトリのある $HOME 配下）に状態を置いて実行するため、現時点では落ちるのが正しい開始状態。/tmp 上では chown が通ってしまうため再現しない）。

## Acceptance
- `tests/run.sh cirunner`
- `tests/run.sh`（既存のテストも全部通ること）

## Notes
- `runners/ci` 以外は編集しない（特に `bin/subcon`、`lib/`、`tests/`、`docs/`、`ci/`、`.github/`）。
- macOS の `/bin/bash` 3.2 で動くこと。
