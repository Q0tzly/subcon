# 57-terms-advisory-wording

## Goal

認証・規約に関する注意書きを、2026-11-13 に確認した Google 公式 FAQ の線引きに合わせて正確にする。README 2か所、docs/delegation.md 1か所、CLI 警告文（lib/common.sh）1か所の文言差し替えのみで、挙動は変えない。

方針: 免責（「自己責任」）にはせず、公式見解と適合な利用形態を事実として併記する。

## Files

- README.md
- docs/delegation.md
- lib/common.sh

## 仕様

### 1. README「現状の制約」の agy バレットを次に差し替える

> - agy の認証が消費者向け Google ログイン（AI Pro など）の場合、`submit` / `resume` は警告を出す。Google の公式 FAQ は、消費者プランのログインをサードパーティ製エージェントやアプリから使うことを規約違反としており、Google アカウント全体の停止・終了の対象になると明記している。subcon 経由で agy を使う形は、起動するのが利用者自身でも「アプリによるラップ」に当たりうる。特に、上位エージェント（Claude Code 等）が subcon を起動して回す運用は、FAQ が非対応とする形そのものである。規約に適合する使い方は2つある。(1) API キー方式: `~/.gemini/antigravity-cli/settings.json` の `modelProvider` を `gemini` にし、`GEMINI_API_KEY` を設定する（キーは Google AI Studio で発行する）。エージェント経由の自動化には、公式が推奨するこの経路を使う。(2) 利用者自身のスクリプト／CI から `agy` を直接呼び出す形（subcon を介さない）。過去に許容と読める案内があったが、現行の FAQ が優先する。詳細は docs/delegation.md。

### 2. README「実行ルート」の self-hosted バレットを次に差し替える

> - **self-hosted（自分のマシンで Actions を回す）**: 実行と agy の認証が利用者自身のマシンに留まるルート。自分の CI／スクリプトから直接 `agy` を呼ぶ限り、消費者サブスクリプションのログインも利用できる（下記「現状の制約」を参照）。エージェントに自動実行を任せる場合は API キー方式を使う。

### 3. docs/delegation.md の認証警告の段落（110–112 行付近）を次に差し替える

> agy の認証が消費者向け Google ログイン（AI Pro など）の場合、`submit` / `resume` は警告を出してから実行する。
> Google の公式 FAQ は、消費者プランのログインをサードパーティ製エージェント（Claude Code 等）やアプリから使うことを規約違反とし、Google アカウント全体の停止・終了のリスクがあるとしている。subcon 経由の利用は、起動者が利用者自身でも「アプリによるラップ」に当たりうるもので、上位エージェントが subcon を起動する運用は明確に非対応の側にある。過去に許容と読めるスタッフ案内があったが、後の明確化で supersede されており、現行 FAQ が優先する。
> 規約に適合する使い方は、(1) API キー方式（`~/.gemini/antigravity-cli/settings.json` の `modelProvider` を `gemini` にして、Google AI Studio で発行したキーを `GEMINI_API_KEY` に設定する。エージェント経由の自動化には公式が推奨するこの経路を使う）、(2) 利用者自身のスクリプト／CI から `agy` を直接呼び出すこと（subcon を介さない）、の2つ。

### 4. lib/common.sh の警告文（warn_consumer_auth）を2点だけ直す

- `risks account suspension` → `risks suspension of your Google account`
- `or run subcon from your own scripts/CI` → `or call agy directly from your own scripts/CI`

文の他の部分は変更しない。

## Acceptance

- 受け入れテスト（tests/run.sh、監督が先行コミット済み）: `test_authwarn_warning_wording` — 警告文に `suspension of your Google account` と `call agy directly` が含まれる。
- 全テスト合格。
