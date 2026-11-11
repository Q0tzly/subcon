# 27: 仕様の切り出し（docs/spec/）

## Goal

公開契約だけを集めた仕様文書 `docs/spec/` を新設し、現行仕様の正本をそちらへ移す。docs/design/ 配下は設計経緯と作業記録として残る。内容は新しい事実の創作ではなく、現行のコードと文書（v2.md、container-runner.md、ci-runner.md、delegation.md、schema/result.schema.json）からの統合・再編。

前提: 票25（`v: 1` と history の `type`）は取り込み済み。票26（`SUBCON_MODEL` → `SUBCON_JOB_MODEL` の改名）は並行実施中で、仕様には改名後の名前で書く。

## Files

- docs/spec/cli.md
- docs/spec/files.md
- docs/spec/runner.md
- docs/spec/backend.md
- docs/design/v2.md
- README.md

## Interface

共通:

- 各文書の冒頭に「仕様の版: 1」と、この文書が現行仕様の正本である旨を置く
- 事実はコードと現行文書から取る。読み取れない点は創作せず、design_questions に残す

docs/spec/cli.md（コマンドの契約）:

- 全コマンドの一覧表（コマンド名・動作・stdout の形）。v2.md のコマンド表を正本化する
- 出力の原則: stdout は JSON のみ、人間向けは stderr。配列になるコマンド（submit / resume / wait）と単体オブジェクトになるコマンド（run / show ほか）の使い分けの原則（複数ジョブを扱えるものは配列）
- 終了コード表（0〜5、複数該当時は大きい方）と、エラーの扱い（前提エラーは stderr＋終了コードで stdout は空、要素単位の失敗は `error` フィールド）
- 主なオプション（--runner / --model / --timeout）と環境変数のうち利用者向けのもの（SUBCON_MODEL、SUBCON_STATE、SUBCON_REVIEWER、SUBCON_COAUTHOR_EMAIL、SUBCON_CONTAINER_ENGINE、SUBCON_CONTAINER_IMAGE）

docs/spec/files.md（ファイル形式の契約）:

- 票フォーマット: パーサが強制するのは `## Files`（1 件以上の妥当なパス）だけであること。他の節（Goal / Interface / Acceptance / Notes）は delegation.md の慣習であることを区別して書く
- meta.json: `v` を含む全フィールドと意味。resume 時の追加フィールド
- result.json: 例と各フィールドの意味。実行中は該当フィールドが null になる規則
- history.jsonl: finalize 行（`type: "job"`）と event 行（`type: "event"`）の 2 種。各フィールド（`v` を含む）。行種別の判定は `.type` で行うこと。`v` の無い旧行も読めること
- state ファイルと patch.diff の位置づけ

docs/spec/runner.md（ランナー契約）:

- 契約本体: 引数（ジョブディレクトリ 1 つ）、前提（work/ と meta.json と ticket.md が準備済み）、責務（agy.json を書く）、終了コード
- env 一覧表: 名前・設定する側・意味。契約変数（SUBCON_PROMPT_FILE、SUBCON_SCHEMA、SUBCON_SETTINGS、SUBCON_JOB_MODEL、SUBCON_TIMEOUT、SUBCON_CONVERSATION）と、実装内部の変数（SUBCON_ROOT、SUBCON_CI_* 群、SUBCON_CONTAINER_* のうち利用者向けでないもの）を区別する
- ランナーごとの拡張: local（stream-json と会話 ID の回収）、container（マウントと env の変換、イメージの作り方の要点）、ci（run-name による相関、artifact の形式 work.tar.gz と agy.json / agy.stream、resume は ci では不可）

docs/spec/backend.md（バックエンド契約）:

- 実装役バックエンドが満たすものの最小契約として書く: プロンプト（lib/prompt.md の役割と、票がそのまま渡ること）、報告スキーマ（schema/result.schema.json の各フィールドと required、status の意味）
- agy.json のうち subcon が読む部分（structured_output、conversation_id、error、usage、duration_seconds）と、会話の継続（resume が conversation_id を使うこと）

docs/design/v2.md と README.md:

- v2.md はタイトル直下に「現行仕様の正本は docs/spec/。この文書は v2 の設計経緯と判断の記録」という注記を 1 つ追加するだけ（他の記述は書き換えない。票26が触っている箇所と重ならないこと）
- README.md は「設計は docs/design/v2.md…」の行に、仕様は docs/spec/ である旨を足す程度の最小変更

## Acceptance

```sh
./tests/run.sh
```

文書のみの変更なので、テストは回帰確認。全通過が合格条件。加えて上位が 4 文書の内容を現行コードと突き合わせて検収する。

## Notes

- 統合元は主に docs/design/v2.md（コマンド表・結果の定義・ランナー契約・使用統計）、docs/design/container-runner.md、docs/design/ci-runner.md、docs/delegation.md（票の節と書式）、schema/result.schema.json、lib/prompt.md
- 票の一覧（00-plan.md や docs/design/v2/ 配下の各票）は作業記録なので、仕様の統合元として参照はするが書き換えない
