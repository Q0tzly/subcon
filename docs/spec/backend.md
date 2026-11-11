仕様の版: 1

この文書は subcon がエージェントバックエンド（agy / Gemini Flash 等）に対して要求する最小契約に関する現行仕様の正本である。

# バックエンド契約仕様

subcon は、実装役となるバックエンド（agy 経由の LLM エージェント）に対してプロンプトおよび構造化出力スキーマを提示し、その実行結果を検証・回収する。

## プロンプト契約

バックエンドに渡されるプロンプトは、`SUBCON_PROMPT_FILE` を介して供給される。

### 通常実行時（初回）

`lib/prompt.md`（システム前文）の直下に、作業票（`ticket.md`）の内容をそのまま連結したテキストが渡る（区切りは挿入されない）。

前文（`lib/prompt.md`）が課すルール:
1. **変更範囲の限定**: 作業票の `## Files` に列挙されたファイルのみを作成または変更すること。他のファイルが必要な場合は変更せず停止し、`design_questions` に記録すること。
2. **git 状態変更の禁止**: git の状態を変更するコマンド（commit, add, reset, checkout, stash, push, rebase など）を実行しないこと。検収とコミットは上位エージェント（レビュアー）が行う。
3. **インターフェースの厳格な実装**: 作業票の `## Interface` に指定された公開シグネチャ・仕様を厳密に実装し、そこに無い余計な公開 API を追加しないこと。
4. **合格条件の自己検証**: `## Acceptance` に記載された全コマンドをバックエンド自身で実行し、各コマンドの実際の終了コード（`exit_code`）を報告すること。
5. **テストの追加**: テストを追加する場合も、`## Files` に記載されたファイル内に限ること。
6. **曖昧さの扱い**: 作業票に曖昧さや矛盾がある場合は最も安全側の解釈を選択し、その疑問と選択理由を `design_questions` に記録すること。
7. **スコープ外の課題**: 作業票のスコープ外で見つけた既存の問題は直接修正せず、`issues_found` に記録すること。
8. **status の報告基準**: `## Acceptance` の全コマンドが exit 0 で合格した場合のみ `status` を `"done"` とすること。未完了または失敗がある場合は `"partial"` または `"blocked"` を設定すること。

### 再開実行時（`resume`）

`subcon resume` による再開時は、票全文ではなく `lib/resume-prompt.md`（再開用プロンプト）のみが渡る。

- プロンプト内容:
  「前回の実行が中断された。作業ツリーには途中までの変更が含まれている。`git status` と `git diff` で現在の状態を確認し、中断した箇所から作業を続けて完了させよ。同じルールと報告形式に従え。」
- 会話履歴（`conversation_id`）が票の内容や前文ルール、前回の試行錯誤を保持しているため、短い指示のみで文脈を引き継ぐ。

## 報告スキーマ契約 (`schema/result.schema.json`)

バックエンドは、agy の `--json-schema` オプションを通じて以下の JSON スキーマに従う構造化出力（`structured_output`）を返さなければならない。

### スキーマフィールド一覧

| フィールド名 | 型 | 必須 | 説明 |
| --- | --- | --- | --- |
| `status` | string (`"done"` \| `"partial"` \| `"blocked"`) | 必須 | 実装状況の自己申告。Acceptance の全コマンドが成功した場合のみ `"done"` |
| `summary` | string | 必須 | 実施した変更や作業内容の要約 |
| `files_changed` | array of string | 必須 | バックエンドが変更・作成したファイルパスの配列 |
| `commands_run` | array of object | 必須 | 実行した検証コマンドの配列（下記参照） |
| `design_questions` | array of string | 必須 | 作業票の曖昧さ・矛盾、および自身が採用した判断の配列 |
| `issues_found` | array of string | 必須 | 作業票のスコープ外で発見した既存の課題・問題の配列 |

すべてのフィールド（6 つ）が `required` である。

#### `commands_run` の要素オブジェクト

- `command` (string, 必須): 実行したコマンド文字列。
- `exit_code` (integer, 必須): コマンドの終了コード。
- `note` (string, 任意): コマンド実行に関する補足説明。

### `status` の意味

- `"done"`: 作業票の目的を達成し、`## Acceptance` に指定された全コマンドを自身で実行してすべて exit 0 で成功した状態。
- `"partial"`: 時間切れや手順の途中で終了し、作業が部分的にしか完了していない状態。
- `"blocked"`: 作業票の前提矛盾、テスト側の不備、権限不足などにより作業の継続が阻害された状態。

## agy.json のうち subcon が解釈する項目

ランナーが出力する `agy.json` のうち、subcon（`lib/job.sh` および `lib/history.sh`）は以下のフィールドを解釈する:

- `structured_output`: バックエンドから返された報告 JSON。`result.json` の `report` および `status` に反映される。
- `conversation_id`: agy セッションの一意な会話 ID。`result.json` の `conversation` および `meta.json` に保存される。
- `error`: agy 自身が記録したエラーメッセージまたはエラーオブジェクト。`result.json` の `agy_error` に反映される。
- `usage`: トークン消費統計オブジェクト（`input_tokens`, `output_tokens`, `total_tokens`, `cache_read_tokens`, `thinking_tokens`）。`history.jsonl` の `tokens` に反映される。
- `duration_seconds`: agy の実行所要秒数（数値）。`history.jsonl` の `duration_s` に反映される。

## 会話の継続（`resume`）

agy は実行が異常終了した場合や kill された場合でも、セッションの `conversation_id` を保持している。

- `subcon resume` は、失敗したジョブの `result.json` から `conversation` を取得する。
- ランナーへ `SUBCON_CONVERSATION=<conversation_id>` を環境変数として渡す。
- local ランナーおよび container ランナーは、agy 起動時に `--conversation <id>` オプションを付与する。
- バックエンドはこれにより、過去の会話履歴（チケット内容・思考プロセス・コマンド実行結果）を破棄せずに、前回の続きから作業を再開する。
