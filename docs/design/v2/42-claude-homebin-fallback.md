# 42-claude-homebin-fallback

## Goal

`drivers/claude` に `drivers/agy` と同じ `$HOME/.local/bin` フォールバックを持たせ、PATH の狭い実行環境（CI ランナーの launchd 環境など）でも公式インストーラが置く `~/.local/bin/claude` を見つけられるようにする。

背景: 票41 の CI + claude 実機確認で、ランナー環境の PATH（`/usr/bin:/bin:/usr/sbin:/sbin`）に `~/.local/bin` が無く、ドライバ本体の実行が `timeout: exec(claude): No such file or directory` で失敗した。agy はドライバ冒頭のフォールバックで同じ環境を通過できている。認証（setup-token の `~/.config/subcon/claude-env` 読み込み）は正常に動いていたので、残る障害はこの PATH 解決だけ。

## Files

- drivers/claude
- docs/spec/runner.md

## 仕様

- `drivers/claude` の冒頭（`case` ディスパッチより前、`drivers/agy` の同等ブロックと同じ位置）にフォールバックを入れる:
  - `command -v claude` が失敗し、`$HOME/.local/bin/claude` が実行可能なら、`$HOME/.local/bin` を PATH の先頭に足す。
  - 書き方は `drivers/agy` の既存ブロック（6〜8行目）と対称にすること。
- `preflight` の「claude not found」メッセージを実態に合わせる: `claude not found: install Claude Code and make sure it is on PATH or at ~/.local/bin/claude`（agy 側の文言と対称）。
- フォールバックは全サブコマンド（`preflight` / `models` / `default-model` / 本実行）に効くこと。冒頭に置けば自然にそうなる。
- `docs/spec/runner.md`: claude ドライバの解決まわりの記述があれば追従する。無ければ変更不要（その場合は Files から外れてよい）。

## やらないこと

- `drivers/opencode` への同種フォールバック（opencode は `~/.opencode/bin` で場所が違い、CI 未対応でもあるため別判断）。
- ランナー側（ワークフローや `ci/run-job.sh`）への PATH 追加。ドライバ自己解決が agy との対称性として正しい置き場所。

## Acceptance

- 受け入れテスト（tests/run.sh、監督が先行コミット済み）:
  - `test_driver_claude_preflight_homebin`: PATH に claude が無く `$HOME/.local/bin/claude` だけがある状態で submit が通り、ジョブが done になる。
  - `test_preflight_claude_fallback_run`: 同条件で `subcon run` が finished/done になり、`subcon trailer` がモデル名（Claude Haiku 5.5）を引ける。
  - 既存の `test_driver_claude_preflight_missing`（claude がどこにも無い場合は従来どおり失敗）が引き続き通る。
- 全テスト合格。
