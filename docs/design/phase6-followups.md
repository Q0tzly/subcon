# フェーズ6 後続（claude の container / ci 対応、OpenCode ドライバ）

状態: 設計メモ（2026-11-12、上位が起草）。決定 A・B は暫定決定
（2026-11-12 ユーザー）。2026-11-13 に Argon レビューを通し、
結果によっては再実装する前提で進める。

## OpenCode × Sakura AI Engine の検証結果（2026-11-12、監督が実測）

接続先候補の Sakura AI Engine（OpenAI 互換 API、
`https://api.ai.sakura.ad.jp/v1`）に対して、OpenCode 1.19.5 を
カスタムプロバイダ（`@ai-sdk/openai-compatible`、baseURL と
`{env:...}` 形式の API キー指定）で接続するスパイクを実施した。

- Sakura 側: トークン有効。`/v1/models` の現在の提供モデルに
  Qwen3-Coder は無く、コーディング系の候補は
  `preview/Kimi-K2.7-Code` と `gpt-oss-120b`。
- Mac mini（実利用に近い環境）では完全に動作した:
  - gpt-oss-120b で即応答（PONG、total 6,400 tokens）。
  - Kimi-K2.7-Code でファイル作成タスクが 45 秒以内に完了
    （tool_use の write で内容も正確）。
  - `--session <id>` による resume で前セッションの文脈が保持される
    ことを確認。
- イベント形式: `--format json` は NDJSON。`sessionID`（`ses_...`）は
  最初の `step_start` イベントから取れる。usage は `step_finish`
  ごとに分かれて出る（`tokens: {total, input, output, reasoning,
  cache: {write, read}}`）ため、ドライバ側で合算する。
  `cost` は Sakura では常に 0（未報告として扱う）。
- セッション ID は opencode が生成し、事前確定はできない
  （drivers/claude の `--session-id` 方式は使えない）。ドライバは
  イベントを `agy.stream` へライブに流し、最初のイベントから
  ID を回収する形にすれば kill 時 resume は保てる。
- `opencode run` に `--json-schema` は無い（→ 決定 A）。
- 環境注記: 検証用 VM（プロキシ経由 egress）では `opencode run` が
  init 直後で止まる事象が 6 回中 5 回起きたが、mini では即応答した
  ため VM 環境固有と判断した。ドライバの `preflight` では実接続の
  確認（温め）まで行う設計が望ましい。

## 決定 A（暫定）: OpenCode ドライバの構造化報告

**`opencode run` にはスキーマ強制の口が無いので、構造化報告は
「プロンプト指示＋ドライバ側パース・検証」で実現する
（2026-11-12 ユーザー暫定決定、Argon レビュー待ち）。**

- ドライバは `SUBCON_PROMPT_FILE` の内容に、`SUBCON_SCHEMA` の
  スキーマ JSON を埋め込んだ報告指示節を足して opencode に渡す
  （最終メッセージはスキーマに沿う JSON オブジェクトのみで返す指示）。
- 終了後、ドライバは最後の `text` イベントを取り出し、JSON
  オブジェクトとして解釈できれば `structured_output` とする。
  解釈できない場合は drivers/claude と同様に ERROR の結果を合成する
  （`error: "opencode exited without a result"` 相当）。
- usage は全 `step_finish` の合算。`reasoning` は `thinking_tokens`、
  `cache.read` / `cache.write` は `cache_read_tokens` へ寄せる
  （write の扱いは実装票で確定する）。`cost_usd` は付けない。

## 決定 B（暫定）: container ランナーでの claude ドライバは API キー方式のみ

**container + claude は `ANTHROPIC_API_KEY` の環境変数持ち込みのみを
対応範囲とする（2026-11-12 ユーザー暫定決定、Argon レビュー待ち）。**

- 根拠: サブスクリプション認証は macOS ホストでは Keychain 内にあり
  コンテナへファイルとしてマウントできない。Linux ホストの
  `~/.claude/.credentials.json` マウントは技術的には可能だが、
  ホスト OS で 2 経路を維持する表面積に見合わない。
- 持ち込みの形は agy の `GEMINI_API_KEY` と同型: ホスト側 env に
  ある場合だけコンテナへ素通しする。鍵をイメージやリポジトリに
  置かないのは従来どおり。
- あわせて配管として: `runners/container` と `container-entry.sh` へ
  `SUBCON_DRIVER` を通し、イメージへ `drivers/claude` と claude 本体を
  同梱する。submit 時のガード（票34）は「container + claude +
  `ANTHROPIC_API_KEY` 未設定」を落とす形に変える。

## 論点 C（未決定）: CI ランナーでの claude 認証 = setup-token 方式

CI ランナー（self-hosted、現行は Mac mini）で claude を使うには、
ランナーの非対話文脈から読める認証が要る。対話ログインは macOS では
Keychain 保存になり、agy で踏んだのと同じ理由で非対話文脈から
読めない。候補は `claude setup-token` が発行する長期トークン:

- `claude setup-token` はブラウザ認証で **1 年有効の OAuth トークン**を
  1 回だけ表示する（どこにも保存されない）。利用側は環境変数
  `CLAUDE_CODE_OAUTH_TOKEN` に入れて使う。公式に「CI パイプラインや
  スクリプトなど、ブラウザログインが使えない環境のため」とされている。
- 課金は API 従量ではなく本人のサブスクリプション枠から
  （Pro / Max / Team / Enterprise が必要。なお 2026-06 以降、
  `claude -p` の利用は対話枠とは別の月次 Agent SDK クレジットから
  引かれる建付けに変わっている）。
- 置き場所の案: GitHub の Secrets には入れず、ランナーマシン上の
  利用者だけが読めるファイル（例: mini の `~/.config/subcon/` 配下、
  権限 600）に置き、ワークフロー／ランナー起動時に環境へ読み込む。
  制御面に鍵を渡さない既定原則と同型（自分のマシン・自分のトークン・
  自分のジョブ）。1 年で失効し自動更新は無いので、失効時期の記録が要る。
- 未決定: この方式で進めるか。代替は「CI + claude は API キー方式のみ」
  （B と揃える）か、「CI + claude は対応しない」。

## 票の候補（Argon レビュー後に登録する）

| 候補 | 内容 |
| --- | --- |
| 37 | `drivers/opencode` 本実装（決定 A の方式、フェイクでの検証、モデル既定は `sakura/preview/Kimi-K2.7-Code`） |
| 38 | container + claude 対応（決定 B: 配管＋ `ANTHROPIC_API_KEY` 素通し＋ガード変更＋イメージ同梱） |
| 39 | ci + claude 対応（論点 C の決定に従う。配管は `SUBCON_CI_DRIVER` の追加が中心） |

監督役モデルのベンチマーク比較は、Claude 週間枠に余裕がある時期に
別途行う（フェーズ6 の順番では最後）。
