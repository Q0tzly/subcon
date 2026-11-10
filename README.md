# subcon

Claude / Codex などの上位エージェントが、作業票を書いた実装ステップを agy 経由の Gemini Flash に下請けに出すための仕組み。
上位は作業票を書き、Flash が実装し、上位が検収してコミットする。

ルール（いつ渡すか・作業票の書式・検収・コミットの trailer）は [docs/delegation.md](docs/delegation.md)。

## セットアップ

```sh
./install.sh
```

- `bin/subcon` → `~/.local/bin/subcon`
- 各エージェントのグローバル指示から `subcon guide` を読ませる（ルールは docs/delegation.md）
- 前提: `agy`（ログイン済み）と `jq`

## 使い方

票（作業票）をジョブとして発行し、結果のパッチを検収して当てる。GitHub Actions のように、発行したら上位は他の作業を続けられる。

```sh
subcon new feat/01-parser          # 票の雛形を作る
subcon submit <ticket>...          # ジョブを発行（ID が返る）
subcon wait --timeout 540 <id>...  # 結果 JSON を待つ
subcon diff <id>                   # パッチを読む
subcon apply <id>                  # 作業ツリーに当てる
subcon discard <id>                # ジョブを消す
subcon guide                       # ルール（docs/delegation.md）を表示
subcon trailer                     # コミット用の Co-Authored-By 行
```

ほかに `run`（submit + wait）、`show`、`list`、`resume`（失敗したジョブを agy の会話ごと再開）、`stats`（履歴の集計）。ジョブは `~/.local/state/subcon/jobs/` に保存され、それぞれ専用の git worktree で実行される。

終了コード: `0` 成功 / `1` 使い方の誤り / `2` Flash が partial・blocked / `3` チェック違反 / `4` ジョブ失敗 / `5` wait のタイムアウト。

## Muse から使う

`./install.sh` は、Muse があれば `skills/subcon` をそのスキル置き場にリンクする（リポジトリと同期）。VM版 Muse では `~/workspace/custom-skills/subcon`、CLI版では `~/.config/muse/skills/subcon`。
dotfiles を入れていれば、`ai/AGENTS.md` が `~/.claude/CLAUDE.md`、`~/.codex/AGENTS.md`、Muse の `~/AGENTS.md` にリンクされるので指示も届く。dotfiles から入れるなら `install.sh --subcon`。
スキルは `subcon guide` を読んでから委任する入口で、手順そのものは `docs/delegation.md` に一本化している。

## 開発

```sh
tests/run.sh            # 全テスト（本物の agy は使わない）
tests/run.sh submit     # グループ指定: ticket submit query manage history stats resume
```

設計は [docs/design/v2.md](docs/design/v2.md)、作業票は [docs/design/v2/](docs/design/v2/)。

## 現状の制約

- agy のサンドボックスは Flash がサンドボックス外で実行するのを止められない（詳細は docs/delegation.md）。隔離した実行環境（コンテナ / Mac mini）のランナーを予定
