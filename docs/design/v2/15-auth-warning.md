# agy の認証方式の検出と警告

## Goal
agy が消費者向け Google ログイン（AI Pro 等）で動いているときに、`submit` / `resume` の前に警告を出す。消費者プランのログインをサードパーティ製エージェント経由で使うことは Antigravity の規約で認められておらず、アカウント停止のリスクがあるため、知らずに使い続ける状態をなくす。警告は止めない（終了コードは変えず、ジョブも作る）。API キー方式なら何も出さない。

## Files
- lib/common.sh
- lib/job.sh

## Interface
`lib/common.sh` に次の 2 関数を足す（名前と引数は変えない）。

- `agy_auth_mode`: 認証方式を stdout に出す。`$HOME/.gemini/antigravity-cli/settings.json` があり、その `modelProvider` が `gemini` なら `api-key`、それ以外（ファイルが無い・壊れている・値が違う）は全部 `consumer`。必ずどちらかを出して 0 を返す（`set -e` の文脈で落ちないこと）
- `warn_consumer_auth`: `agy_auth_mode` が `consumer` で、かつ `SUBCON_NO_AUTH_WARNING` が未設定または空のとき、警告文を stderr に出す。`api-key` のときと、警告を消す指定があるときは何も出さない。常時 0 を返す

警告文は次の内容を 1 行で（文言は意味が同じ範囲で調整可）:

```
subcon: warning: agy is using a consumer Google login. Driving agy from a third-party agent on a consumer plan (AI Pro etc.) violates Antigravity's terms and risks account suspension. Supported options: switch agy to an API key (set "modelProvider": "gemini" in ~/.gemini/antigravity-cli/settings.json and export GEMINI_API_KEY), or run subcon from your own scripts/CI. Silence with SUBCON_NO_AUTH_WARNING=1.
```

呼び出し側:

- `lib/job.sh` の `cmd_submit` と `cmd_resume` は、`require_agy` の直後に `warn_consumer_auth` を呼ぶ（`cmd_run` は `cmd_submit` 経由なので変更しない）。`cmd_trailer` や agy を使わないコマンドには入れない

合格テストは上位が先に書いてコミット済み（`tests/run.sh` に authwarn グループを追加）。現時点で authwarn グループは 5 件中 2 件落ちるのが正しい開始状態（警告そのものがまだ無いため）。

## Acceptance
- `tests/run.sh authwarn`
- `tests/run.sh`（既存のテストも全部通ること）

## Notes
- `lib/common.sh` と `lib/job.sh` 以外は編集しない（特に `bin/subcon`、`tests/`、`docs/`、`runners/`）。
- macOS の `/bin/bash` 3.2 で動くこと（連想配列・`mapfile`・`${x,,}` は使わない。`set -u` 下で空配列を `"${a[@]}"` と展開しない）。`$HOME` が未設定でも落ちないこと。
- settings.json の読み取りは `jq` を使う（subcon は他でも jq に依存している）。読めない場合は `consumer` として扱う。
