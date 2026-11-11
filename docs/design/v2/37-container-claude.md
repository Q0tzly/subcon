# 37-container-claude

## Goal

container ランナーで `claude` ドライバを使えるようにする（フェーズ6 後続、設計は ../phase6-followups.md の決定 B と Q5 の必須事項）。認証は `ANTHROPIC_API_KEY` の持ち込みのみ（サブスクリプション認証はコンテナへ持ち込まない）。ci ランナーは本票では変更しない（票38）。

## Files

- lib/job.sh
- runners/container
- runners/container-entry.sh
- container/Containerfile
- docs/spec/cli.md
- docs/spec/runner.md

## Interface

### lib/job.sh — submit / resume のガード

現行の単一ガード（`container` / `ci` とも `driver != agy` で `the $runner runner supports the agy driver only`）を以下に置き換える。位置は現行どおり `require_driver` の後、`require_container` の前:

- `ci` かつ `driver != agy` → `die "the ci runner supports the agy driver only"`（現行文のまま）。
- `container` かつ `driver` が `agy` でも `claude` でもない → `die "the container runner supports the agy and claude drivers only"`。
- `container` かつ `driver == claude` かつ `ANTHROPIC_API_KEY` が未設定または空 → `die "the container runner with the claude driver requires ANTHROPIC_API_KEY"`。

`cmd_resume` にも同じ条件を入れる: 再開元ジョブの `runner` が `container` で `driver` が `claude` の場合、`ANTHROPIC_API_KEY` が無ければ同じ文で `die` する（現行の `require_container` 呼び出しの前）。

### runners/container — ドライバの伝播とマウント・env

- ドライバは環境変数 `SUBCON_DRIVER`（`job_exec` が export 済み。無ければ `agy`）で判断する。
- マウント: `driver == agy` のときは現行どおり `$home_dir/.gemini` → `/home/runner/.gemini`。`driver == claude` のときは代わりに `$home_dir/.claude` → `/home/runner/.claude` をマウントする（`mkdir -p` も対象をドライバに合わせる）。**ドライバのディレクトリだけをマウントし、両方はマウントしない**。claude のマウントの目的は認証ではなく会話ファイルの永続化（resume を成立させるため）。
- env: 起動引数に `-e SUBCON_DRIVER="$driver"` を追加する（値つきで渡す）。
- `ANTHROPIC_API_KEY` が非空なら、`GEMINI_API_KEY` と同型に名前だけを `extra_env` 経由で渡す（`-e ANTHROPIC_API_KEY`。値を引数に埋めない）。未設定・空なら渡さない。
- それ以外の振る舞い（イメージ名、`--user`、work/job マウント、schema のコピー等）は無変更。

### runners/container-entry.sh — ドライバ解決の統一

- `driver_bin` の決定を `SUBCON_DRIVER_BIN` から **`subcon-driver-${SUBCON_DRIVER:-agy}`** に変える。`SUBCON_DRIVER_BIN` は廃止する。

### container/Containerfile — claude の同梱

- `drivers/agy` の COPY の直後に `drivers/claude` を `/usr/local/bin/subcon-driver-claude` として COPY し、chmod 755 する。
- runner ユーザーの導入手順（agy の公式インストーラ実行の直後）に、claude を公式インストーラで取得する行を追加する: `RUN curl -fsSL https://claude.ai/install.sh | bash`（再配布回避のためバイナリは同梱しない。agy と同型）。

### docs/spec/cli.md

- 「主なオプション」の `--driver D` の説明のうち「`container` / `ci` ランナーは `agy` ドライバのみ対応し、それ以外は submit 時に終了コード 1 で失敗する」の部分を、現行仕様に合わせて書き換える: `ci` ランナーは `agy` のみ。`container` ランナーは `agy` と `claude` に対応し、`claude` の場合は `ANTHROPIC_API_KEY` が必要（無い場合は submit 時に終了コード 1）。

### docs/spec/runner.md（container ランナー節）

- 冒頭文を「使い捨てコンテナ内でドライバ（`agy` / `claude`）を実行する隔離ランナー」に変える。
- マウント構成: `.gemini` の行に「（`driver=agy` のとき）」を付け、`.claude` の行を追加する: `$HOME/.claude` → `/home/runner/.claude`（rw、`driver=claude` のとき。会話ファイルの永続化用。認証は `ANTHROPIC_API_KEY` 環境変数）。
- 「環境変数の変換」に追記する: `SUBCON_DRIVER` をコンテナへ渡し、entry が `subcon-driver-<name>` を解決する。`ANTHROPIC_API_KEY` はホスト側に設定されている場合のみ名前だけを渡す。
- 「イメージ作成の要点」に追記する: claude バイナリもイメージに同梱せず公式インストーラ（`https://claude.ai/install.sh`）経由で取得する。`drivers/claude` は `subcon-driver-claude` として同梱する。

## Acceptance

- [ ] `./tests/run.sh container`
- [ ] `./tests/run.sh driver`
- [ ] `./tests/run.sh`
- [ ] `grep -q 'subcon-driver-claude' container/Containerfile`
- [ ] `grep -q 'claude.ai/install' container/Containerfile`

## Notes

- 本票の実装役は Haiku（subcon シム経由。尽きたら Flash）。
- テストは監督側が用意済み（`tests/run.sh` の container / driver グループ。FAKEBIN への `subcon-driver-claude` リンクも監督側）。テストファイルは変更しないこと。
- 実機のコンテナ実行確認（mini でイメージをビルドし container + claude の実ジョブを通す）は監督側が実施する。本票の受け入れには含めない。
- `drivers/claude` 自体は変更しない。preflight への env 分岐も追加しない（`claude auth status` が `ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN` 設定時に `loggedIn: true` を返すことを監督が実機確認済み。phase6-followups.md の精査記録参照）。
