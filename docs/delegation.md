# Flash への実装委任

上位エージェント（Claude / Codex など）が、実装の一部を agy 経由の Gemini Flash に渡すときのルール。
全エージェント共通。`subcon guide` で表示できる。

## 最短手順

```sh
subcon new myfeat/01-parser                     # 票の雛形。書いたらコミットする（ジョブは HEAD から始まる）
git add docs/design/myfeat && git commit -m "add: ticket for parser"
subcon submit docs/design/myfeat/01-*.md docs/design/myfeat/02-*.md   # 独立した票は並行に
subcon wait --timeout 540 <id> <id>             # 終了コード 5 なら繰り返す
subcon diff <id>                                # 全部読む
subcon apply <id>                               # 作業ツリーに当てる（コミットはしない）
<Acceptance のコマンドを自分で実行>
subcon commit -m "feat: ..." <id>               # trailer を自動付与（要 SUBCON_REVIEWER。修正時は --edited）
subcon discard <id>
```

stdout は JSON（`diff` `guide` `trailer` を除く）、進捗とエラーは stderr。

ジョブが `failed` で結果に `conversation` があれば、`subcon resume <id>` で途中の作業と agy の会話を引き継いで再開できる（新しい ID が返る。`wait` で待つ）。`conversation` が `null` なら票を出し直す。

## 既定は自分でやる

次の 3 つを**全部**満たすときだけ Flash に渡す。1 つでも欠けたら自分で実装する。

- **作業票が書ける**: 触るファイル・公開インターフェース・合格条件（実行するコマンド）が事前に確定している
- **実装量がある**: 作業票を書いて検収する手間より、自分で書く方が高くつく
- **失敗しても diff を捨てるだけで済む**: 破壊的操作・外部への反映・課金を含まない

数行の修正、設計判断を含む変更、調査が主の作業は委任しない。
途中で「渡すべきでなかった」と分かったら、再委任せずその場で引き取る。

## 流れ

1. **設計 doc** を書く（置き場は下記）。別モデルにレビューさせる（Claude が書いたら Codex、など）
2. **詳細設計**として作業票を並べる。レビューはインターフェースと合格条件だけ見せれば足りる
3. 作業票をコミットして `subcon submit` で Flash に渡す。依存の無い票は並行に出してよい
4. **検収**（下記）。通ったら上位がコミットする
5. 食い違いや Flash の指摘が出たら、**コードより先に設計 doc を直す**。直した票で再委任するか、自分で直す

## 監督の分担

上位の仕事は重さが違うので、モデルを分けてよい。

| 仕事 | 担当 |
| --- | --- |
| 設計 doc・作業票・合格テストを書く（機能ごとに 1 回） | 強いモデル（Opus など）。設計は別系統のモデル（Codex など）にもレビューさせる |
| 委任・検収・コミットの繰り返し | 安いモデル（Sonnet など）をサブエージェントにしてよい |
| 安いモデルが通したコミットの読み直し | 強いモデル。最初のうちは毎回、見逃しが無いと分かってきたら間引く |

- サブエージェントには、票のパス・この手順（`subcon guide`）・やってはいけないこと・最終報告の形（票ごとに確かめたこと、見つけた問題と対処、コミット、未検証の点）を渡す
- 2026-11 の試行（票 10・11、`subcon stats`）: Sonnet の検収で実装の見逃しは無かった。Sonnet は仕様外の問題（強制終了でロックが残る）と仕様の曖昧さ（丸めの桁）も報告した。サブエージェントのトークンは 2 票で約 8 万

## 作業票

1 票 = 1 ステップ = 1 コミット相当。`subcon` はこの見出しを前提にする（`## Files` は機械的にチェックされる）。

```markdown
# <ステップ名>

## Goal
何を実現するか。1〜3 文。

## Files
- src/foo.rs
- tests/foo_test.rs

## Interface
公開する型・関数のシグネチャ、CLI の引数、ファイル形式など。ここに無いものは公開しない。

## Acceptance
- `cargo test foo`
- `cargo clippy -- -D warnings`

## Notes
前提・既存コードの参照先・やってはいけないこと。
```

- 合格条件は**上位が決める**。テストは票より先に上位が書いてコミットしておく。Flash が書くテストは自分の実装に合わせがちなので、追加分として扱う
- 上位のテストにもバグはある。Flash が「テストが間違っている」と blocked で返してきたら、確かめて上位が直す（Flash にはテストを触らせない）
- テストは agy のサンドボックス内でも動くようにする（例: git を使うなら `GIT_CONFIG_GLOBAL=/dev/null`）。動かないと Flash はサンドボックス外で実行する
- 実行環境の制約を `## Notes` に書く（例: macOS の bash 3.2 で動くこと）
- `Acceptance` に全テストを書くなら、後の票の分のテストが未実装で落ちることに注意する。その票と実装済みの票のテストだけを指定する（でないと Flash は正しく partial を返す）
- `Files` に無いファイルを変更したら差し戻し
- 曖昧さを残さない。Flash は穴を推測で埋める

## 委任の実行

- ジョブは発行時の `HEAD` から専用の worktree で動き、上位の作業ツリーには触らない。待っている間も上位は作業を続けられる
- 既定のモデルは `gemini-3.8-flash-medium`。量が多い・難しめの票は `--model gemini-3.8-flash-high`
- `subcon list` でこのリポジトリのジョブ一覧、`subcon show <id>` で 1 件

| 終了コード | 意味 | 次にやること |
| --- | --- | --- |
| 0 | done、チェックも OK | 検収 |
| 2 | Flash が partial / blocked を申告 | `report.summary` と `design_questions` を読む。原因が票やテストなら上位が直して再発行 |
| 3 | コミットした・`## Files` 外を変更した | `checks` を見る。パッチを捨てて票を直す |
| 4 | ジョブが失敗（agy のエラー・タイムアウト・ランナー消失） | `error` と `log` を見る。下記の再開を検討 |
| 5 | `wait` のタイムアウト | もう一度 `wait` |

### 中断したジョブの再開

ネットワークエラーなどで落ちたときは、`subcon resume <id>` で続きから再開できる（v2.1 で実装済み）。
対象は `state: failed` で結果の `conversation` が `null` でないジョブ。再開は新しいジョブとして発行されるので、新しい ID を `wait` で待つ。元のジョブは残り、再開したジョブがまた失敗したらそれをさらに `resume` できる。`conversation` が `null` なら再開できないので、票を `submit` し直す。

### agy の認証方式

agy の認証が消費者向け Google ログイン（AI Pro など）の場合、`submit` / `resume` は警告を出してから実行する。
消費者プランのログインをサードパーティ製エージェントから使うことは Antigravity の規約で認められておらず、アカウント停止の対象になりうるため。
サポートされる形は、agy を API キー方式に切り替える（`~/.gemini/antigravity-cli/settings.json` の `modelProvider` を `gemini` にして `GEMINI_API_KEY` を設定）か、自分自身のスクリプト／CI から使うこと。
警告は `SUBCON_NO_AUTH_WARNING=1` で消せる（自分の CI 等、使い方を把握している場合用）。

### サンドボックスの限界

agy はヘッドレスでは許可されていないコマンドを自動拒否し、その時点で実行全体が止まる。
そのため `subcon` は全コマンドを許可し、git の状態変更・`gh`・`sudo`・`rm -rf` だけを deny している。
agy にはサンドボックス外実行（`BypassSandbox`）を CLI から禁止する設定がなく、全許可だとサンドボックス外でも通る（deny は外でも効く）。
つまり Flash はリポジトリ外にも書けうる。秘密情報のあるディレクトリで使わない、`## Notes` で禁止事項を明示する、で補う。

## 検収

自己申告を信じない。

- `subcon diff <id>` を全部読む。Flash の申告ではなく `checks.files_changed` を見る
- `Acceptance` のコマンドを**自分で**実行する
- Flash の `design_questions` / `issues_found` を読み、設計に反映すべきか判断する
- テストが通っても、テストの無い性質（シグナル・競合・後片付けなど）は読んで確かめる

## 打ち切り

- 再委任は 1 票につき 2 回まで。駄目なら設計に戻るか、上位が直す
- 差し戻し時は「何が駄目だったか」を票の `Notes` に追記してから渡す

## コミット

検収を通ったものだけを上位がコミットする。Flash にはコミットさせない（未検収のものが履歴に入るため）。

上位のレビュアー名義をあらかじめ環境変数 `SUBCON_REVIEWER` に設定しておく。

```sh
export SUBCON_REVIEWER='Name <email>'
```

検収が通ったら、`subcon commit` でコミットする:

```sh
subcon commit -m <message> [--edited] <id>
```

- trailer（`Co-Authored-By` 実装者／`Reviewed-By` レビュアー）が自動で付く
- 検収後に上位が手を入れた場合は `--edited` を付けると、レビュアーの `Co-Authored-By` も追加される
- ジョブの範囲外の変更や未追跡ファイルはコミットに巻き込まれない（`checks.files_changed` のファイルのみステージされる）

手動でコミットする場合の trailer 形式は従来通り:

```
Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>
Reviewed-By: <上位エージェントのモデル名> <そのアドレス>
```

- 上位が検収後に手を入れたら、上位も `Co-Authored-By` に加える
- 実装者の行は `subcon trailer` が出す
- Gemini のアドレスは公式の noreply が確認できなかったので `noreply@google.com` に決め打ち（`SUBCON_COAUTHOR_EMAIL` で変更可）

## プロジェクト側の規約

- 設計 doc: `docs/design/<機能名>.md`
- 作業票: `docs/design/<機能名>/NN-<ステップ名>.md`（番号順に実行）
- 作業票は設計の一部としてコミットしてよい
