# フェーズ6 後続（claude の container / ci 対応、OpenCode ドライバ）

状態: 設計メモ（2026-11-12、上位が起草）。決定 A・B は暫定決定
（2026-11-12 ユーザー）。Argon レビュー回答（2026-11-12）を受け、
監督が実コードと実機で精査した結果を反映済み（末尾の「レビュー精査の
記録」参照）。論点 C は Argon 推奨案を提示してユーザー決定待ち。

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
  ため VM 環境固有と判断した。対策は preflight ではなくドライバ本実行の
  ウォッチドッグとする（Q8 の精査結果。後述の決定 A 参照）。

## 決定 A（暫定）: OpenCode ドライバの構造化報告

**`opencode run` にはスキーマ強制の口が無いので、構造化報告は
「プロンプト指示＋ドライバ側パース・検証」で実現する
（2026-11-12 ユーザー暫定決定。抽出・検証と失敗時の扱いは
Argon レビュー Q1 を採用して改訂）。**

- 実装形態は CLI（`opencode run`）とする。`opencode serve` や SDK は
  デーモン管理・ Node 依存を持ち込むため採らない（Q1）。
- ドライバは `SUBCON_PROMPT_FILE` の内容に、`SUBCON_SCHEMA` の
  スキーマ JSON を埋め込んだ報告指示節を足して opencode に渡す
  （最終メッセージはスキーマに沿う JSON オブジェクトのみで返す指示）。
- 抽出は3段階で試みる: (a) 最後の `text` イベント全体の JSON 解釈、
  (b) ```json コードフェンス内の抽出、(c) 最初の `{` から最後の `}`
  までの部分文字列。解釈できたら必須6キー
  （`status`, `summary`, `files_changed`, `commands_run`,
  `design_questions`, `issues_found`）と `status` の enum
  （`done` / `partial` / `blocked`）を検証し、通れば
  `structured_output` とする。
- **パース・検証に失敗した場合**（opencode 自体は完走）: ERROR は
  合成せず、`status: "SUCCESS"` かつ `structured_output` なしで
  `agy.json` を書き、ドライバは終了コード 0 で終える。上位は
  `result.json` の `status: null` / `report: null` と `checks` で
  検収する（Q1）。あわせてホスト側の追従として、`lib/query.sh` の
  `exit_code_for` で `.status == null`（state は finished）を
  コード 2 扱いにする（報告なしの成功を無言で通さない）。
- usage は全 `step_finish` の合算。`reasoning` は `thinking_tokens`、
  `cache.read` は `cache_read_tokens`、**`cache.write` は捨てる**
  （Q3。drivers/claude が cache_creation を捨てているのと揃える）。
  `total_tokens` は opencode の報告する `total` の合算とする
  （実測では total = input + output + reasoning で一致）。
  `cost_usd` は付けない（Q4）。
- 起動ウォッチドッグ（Q8）: 本実行で最初の `step_start` が
  一定時間（実装票で確定、目安 15〜20 秒）以内に出なければ、
  プロセスを kill して 1 回だけ再起動する。この時点ではモデルが
  まだ動いておらず副作用も課金も無い。`preflight` はローカルの
  存在確認のみに留める（`commit` / `trailer` 等でも毎回呼ばれるため）。
- `default-model` は `SUBCON_OPENCODE_DEFAULT_MODEL` で上書き可能に
  する（Q7）。モデル ID は `provider/model` 形式のまま扱う。
  登録外モデルでも `subcon commit` / `trailer` が詰まらないよう、
  `model_name` が `models` に無い場合はモデル ID 自体へ
  フォールバックする（ホスト側の小さな追従、Q7）。

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
- Argon レビュー Q5 で確定した実装時の必須事項:
  1. `container-entry.sh` は現行 `SUBCON_DRIVER_BIN` を参照している。
     `SUBCON_DRIVER` を渡して entry 側で
     `subcon-driver-${SUBCON_DRIVER:-agy}` を解決する形に統一する。
  2. **resume のため `~/.claude` をマウントする**: コンテナは使い捨て
     （`--rm`）なので、会話ファイルの置き場である `~/.claude` を
     ホストと共有しないと container + claude の resume が成立しない。
     認証は API キーのまま、マウントはセッション永続化のため。
  3. `drivers/claude` の preflight への env 分岐追加は**不要と判明**
     （精査記録参照）。

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
- **Argon の推奨（Q6）**: setup-token を第一とし、`ANTHROPIC_API_KEY`
  もフォールバックとして許容する両対応。読み込みは「環境変数が既に
  あればそれを使い、無ければ `~/.config/subcon/claude-env`（600）を
  source」。1年失効への対処として、失効日ファイル
  （`~/.config/subcon/claude-token-expires`）と、認証失敗時に失効を
  疑うヒントを stderr に出す仕掛けを推奨。ユーザーの決定待ち。

## 票の構成（Argon レビュー Q9 の並べ替えを採用）

| 票 | 内容 |
| --- | --- |
| 37 | container + claude 対応（決定 B＋ Q5 の必須事項: 配管統一、`ANTHROPIC_API_KEY` 素通し、`~/.claude` マウント、ガード変更、イメージ同梱） |
| 38 | ci + claude 対応（論点 C の決定に従う。配管は `SUBCON_CI_DRIVER` の追加と認証 env の読み込みが中心） |
| 39 | `drivers/opencode` 本実装（改訂後の決定 A、ウォッチドッグ、usage 写像、`model_name` フォールバック、`exit_code_for` の null→2 追従） |
| 40 | 履歴・統計への `driver` 記録（`history.jsonl` に `driver`、`stats` に `by_driver`。Q10）と、会話 ID 保証の2段階の仕様明記（Q2: `docs/spec/backend.md` / `runner.md`） |

監督役モデルのベンチマーク比較は、Claude 週間枠に余裕がある時期に
別途行う（フェーズ6 の順番では最後）。既定ドライバの切替判断は
Q10 の指標（一次検収通過率・異常終了率・クォータ持続性）が
`history.jsonl` の driver 記録で測れるようになってから行う。

## レビュー精査の記録（2026-11-12、監督が実コード・実機で確認）

- Q1 の力学は正確: スキーマ必須6キーと status enum は
  `schema/result.schema.json` のとおり。ドライバ exit 非0 →
  `state: failed`（ただし patch と checks は finalize 前段で生成
  される）、`structured_output` 欠落 + exit 0 → `state: finished` で
  `status: null` / `report: null` になることを `lib/job.sh` で確認。
  現行 `exit_code_for` は `.status == null` を 0 に落とすことも確認。
- Q2: `drivers/agy` も stream の最初の `init` イベントから ID を
  回収するベストエフォートであり、opencode と保証レベルは同等。
- Q3: `drivers/claude` は `cache_read_input_tokens` のみを写し
  `cache_creation_input_tokens` を捨てていることを確認。
  opencode の `total` は実測2件とも input + output + reasoning と一致。
- Q4: `lib/history.sh` / `lib/stats.sh` は現状 `cost_usd` を
  抽出・集計していないことを確認（影響なし）。
- Q5/Q6 の preflight 懸念は**実機で否定**: 空の HOME（ログイン無し）
  でも `claude auth status`（2.1.322）は `CLAUDE_CODE_OAUTH_TOKEN`
  設定時に `loggedIn: true`（`authMethod: oauth_token`）、
  `ANTHROPIC_API_KEY` 設定時に `loggedIn: true`（`api_key`）を返し、
  どちらも無ければ `false`。現行 preflight のままで env 認証を通せる
  ため、分岐追加は行わない（版依存の余地はあるが、現行の正は
  auth status とする）。
- Q7: `cmd_trailer` が未登録モデルで `die` することは確認済み
  （票34 検収時）。モデル文字列は JSON のキー・値としてのみ使われ、
  パスやジョブ ID には使われない。
- Q8: `preflight` が `commit` / `trailer` / `reject` でも毎回呼ばれる
  ことは票36 検収時に確認済み。温めを preflight に入れない判断は正。
- Q10: `history_append_job` の記録項目に `driver` が無いことを確認
  （model と runner のみ）。
