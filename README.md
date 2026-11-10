# subcon

Claude / Codex などの上位エージェントが、作業票を書いた実装ステップを agy 経由の Gemini Flash に下請けに出すための仕組み。
上位は作業票を書き、Flash が実装し、上位が検収してコミットする。

ルール（いつ渡すか・作業票の書式・検収・コミットの trailer）は [docs/delegation.md](docs/delegation.md)。

## セットアップ

```sh
./install.sh
```

- `bin/subcon` → `~/.local/bin/subcon`
- `docs/delegation.md` → `~/.config/agents/delegation.md`（各エージェントのグローバル指示からここを参照させる）
- 前提: `agy`（ログイン済み）と `jq`

## 使い方

```sh
subcon run docs/design/foo/01-bar.md   # 作業票 1 枚を Flash に渡す
subcon trailer                         # コミット用の Co-Authored-By 行
```

終了コード: `0` done / `2` Flash が partial・blocked を申告 / `3` コミットした・`## Files` 外を変更した。

## 現状の制約

agy のサンドボックスは Flash がサンドボックス外で実行するのを止められない（詳細は docs/delegation.md）。
隔離した実行環境（コンテナ / Mac mini）でパッチだけ持ち帰る形に移す予定。
