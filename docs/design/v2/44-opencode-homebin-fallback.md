# 44-opencode-homebin-fallback

## Goal

`drivers/opencode` に、票42 で `drivers/claude` に入れたのと同じ形のホームディレクトリ配下バイナリへのフォールバックを持たせる。opencode の公式配置先は `$HOME/.opencode/bin/opencode` で、PATH の狭い環境（CI ランナーや素のシェル）では `command -v opencode` が失敗する。

## Files

- drivers/opencode
- docs/spec/runner.md

## 仕様

- `drivers/opencode` の冒頭（`case` ディスパッチより前）にフォールバックを入れる。書き方は `drivers/agy` / `drivers/claude` の既存ブロックと対称に:
  - `command -v opencode` が失敗し、`$HOME/.opencode/bin/opencode` が実行可能なら、`$HOME/.opencode/bin` を PATH の先頭に足す。
- `preflight` の文言を実態に合わせる: `opencode not found: install OpenCode and make sure it is on PATH or at ~/.opencode/bin/opencode`。
- フォールバックは全サブコマンド（`preflight` / `models` / `default-model` / 本実行）に効くこと。
- `docs/spec/runner.md`: opencode の PATH 解決の記述があれば追従する。無ければ変更不要。

## Acceptance

- 受け入れテスト（tests/run.sh、監督が先行コミット済み）:
  - `test_driver_opencode_preflight_homebin`: PATH に opencode が無く `$HOME/.opencode/bin/opencode` だけがある状態で submit が通り、ジョブが done になる。
  - 既存の `test_driver_opencode_preflight_missing`（どこにも無い場合は従来どおり失敗）が引き続き通る。
- 全テスト合格。
