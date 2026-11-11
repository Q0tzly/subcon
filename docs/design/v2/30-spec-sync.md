# 30-spec-sync

## Goal

Argon の技術レビューで残った仕様と実装の乖離を、`docs/spec/`（現行仕様の正本）側に寄せて解消する。コードは変更しない。ドキュメントのみの票。

## Files

- docs/spec/cli.md
- docs/spec/files.md
- docs/spec/runner.md
- docs/spec/backend.md

## Interface

### docs/spec/cli.md

1. コマンド一覧に `subcon log <id>` の行を `diff` の行の直後へ追加する。動作:「ジョブの実行ログ（ジョブディレクトリの `log` ファイル）をそのまま出力する。実行中のジョブでも読める」。stdout の形式:「テキスト: ログテキスト」。
2. 「出力の原則」の stdout 例外に `log`（ログテキスト）を追加する。
3. agy の解決を必要とするコマンドの列挙に `commit` を追加し、列挙を「`submit`, `run`, `resume`, `commit`, `reject`, `trailer`」の順・表記にする（票29で `commit` も agy 必須になった）。
4. 「出力の原則」に版 `v` の所在を追記する: ジョブ結果オブジェクト（`show` / `wait` / `run` が返すもの）には `v: 1` が付く。`list` の要約オブジェクトと `stats` の集計オブジェクトには `v` を付けない。
5. 終了コード表の直後に注記を追加する: 「`show` も同じ規則で単一ジョブの終了コードを返す（実行中・待機中のジョブは 0）。コード 5 は `wait` のタイムアウト時のみ発生する」。
6. コマンド一覧の直後に「### reject の委任上限」という小節を新設し、次を明記する: 同一リポジトリ・同一票に対する初回委任は最大で 3 件まで。`resume` 由来のジョブは数えない。上限到達時の `reject` は終了コード 1 で失敗し、票・履歴・git のいずれも変更しない。
7. 「主なオプション」の直前に「## stats の出力スキーマ」という節を新設し、集計 JSON の全キーを定義する: `scope`（`repo` | `all`）、`repo`（パス。`--all` 時は null）、`since`（指定文字列または null）、`jobs`（対象ジョブ総数）、`by_state`（`finished` / `failed` の件数）、`by_status`（`done` / `partial` / `blocked` / `none` の件数）、`success`（`state` が finished かつ `status` が done かつチェック合格の件数）、`success_rate`（`success / jobs`。0.0〜1.0、ジョブ 0 件では null）、`applied`（履歴に `applied` イベントがあるジョブの件数）、`apply_rate`（同率・同規則）、`duration_s`（`total` と `median`、単位は秒。データがなければ null）、`tokens`（`input` / `output` / `total` / `cache_read` / `thinking` の合計）、`by_model`（モデル ID をキーに `jobs` / `success` / `applied` / `tokens_total` を持つオブジェクト）。
8. 「利用者向け環境変数」に 2 件追加する: `SUBCON_NO_AUTH_WARNING`（設定すると agy の認証方式に関する警告を表示しない）、`GEMINI_API_KEY`（subcon 自身は読み取らないが、agy の API キー認証に使われる環境変数で、subcon 経由の実行にも影響する）。

### docs/spec/files.md

9. `## Files` 節の要件のうち「前後のバッククォートや空白は除去されて解釈される」という趣旨の箇条書きを、実装どおりの記述に置き換える（古い文面は残さない）。置き換え後の内容: 各エントリは最初の空白で切り捨てられ、空白以降の文字列は注記として無視される。したがってパス自体に空白文字は使えない。バッククォートは除去される。
10. 同じ節に追記する: 節は `## ` で始まる次の見出しで終わるが、`### ` 等の下位見出しでは終わらない（リスト行でない行は無視される）。
11. 同じ節に追記する: パーサは各パスの存在やファイル／ディレクトリの別を検証しない（構文のみ）。範囲チェックは変更されたファイルのパスとの完全一致で行われるため、ディレクトリを指定しても配下のファイルは許可範囲にならない。ファイルの完全な相対パスを列挙すること。
12. `result.json` の `files_changed` の説明付近に注記を追加する: ビルドツール等の生成ファイル（例: `Cargo.lock`）も `files_changed` に含まれるため、`## Files` に無い生成物が生じるとチェック違反（範囲外変更）になる。生成物が予見される票では `## Files` に含めること。

### docs/spec/runner.md

13. 「責務」節に 2 項追加する: (a) ランナーの標準出力は回収されない。ジョブの `log` ファイルに残るのは標準エラー出力のみであり、診断情報は標準エラー出力へ書くこと。(b) subcon はジョブの終了・破棄時にランナーへ SIGTERM を送ることがある。ランナーは SIGTERM を受けたら子プロセスを含めて速やかに（目安として 5 秒以内に）終了すること。
14. 環境変数一覧表の `SUBCON_CI_POLL` の行について、「設定する側」を「テスト / 内部」に変更し、意味に「通常の利用では設定不要」と添える。
15. ci ランナーの拡張節に、利用者リポジトリ側のワークフロー契約を明記する: 配置は `.github/workflows/subcon-job.yml`、`workflow_dispatch` の入力は `job` / `ticket` / `base` / `model` / `timeout` の 5 つ、成果物 `subcon-artifact` の中身は `work.tar.gz` / `agy.json` / `agy.stream`。

### docs/spec/backend.md

16. プロンプト契約（通常実行時）の連結に関する記述を実装どおりに直す: 「改行を挟んで」という表現を削除し、前文ファイルと票ファイルをそのまま連結したテキストが渡る（区切りは挿入されない）という内容にする。

## Acceptance

- [ ] `grep -q 'subcon log' docs/spec/cli.md`
- [ ] `grep -q 'resume`, `commit`, `reject`' docs/spec/cli.md`
- [ ] `grep -q 'には `v` を付けない' docs/spec/cli.md`
- [ ] `grep -q '`show` も同じ規則' docs/spec/cli.md`
- [ ] `grep -q 'reject の委任上限' docs/spec/cli.md`
- [ ] `grep -q '最大で 3 件' docs/spec/cli.md`
- [ ] `grep -q 'stats の出力スキーマ' docs/spec/cli.md`
- [ ] `grep -q 'success_rate' docs/spec/cli.md`
- [ ] `grep -q 'cache_read' docs/spec/cli.md`
- [ ] `grep -q 'SUBCON_NO_AUTH_WARNING' docs/spec/cli.md`
- [ ] `grep -q 'GEMINI_API_KEY' docs/spec/cli.md`
- [ ] `grep -q '最初の空白で切り捨て' docs/spec/files.md`
- [ ] `grep -q '下位見出しでは終わらない' docs/spec/files.md`
- [ ] `grep -q 'ディレクトリを指定しても' docs/spec/files.md`
- [ ] `grep -q 'Cargo.lock' docs/spec/files.md`
- [ ] `! grep -q '空白は除去されて' docs/spec/files.md`
- [ ] `grep -q '標準出力は回収されない' docs/spec/runner.md`
- [ ] `grep -q '診断情報は標準エラー出力へ書く' docs/spec/runner.md`
- [ ] `grep -q 'SIGTERM' docs/spec/runner.md`
- [ ] `grep -q '5 秒以内' docs/spec/runner.md`
- [ ] `grep -q 'SUBCON_CI_POLL` | テスト / 内部' docs/spec/runner.md`
- [ ] `grep -q 'workflow_dispatch' docs/spec/runner.md`
- [ ] `grep -q 'work.tar.gz' docs/spec/runner.md`
- [ ] `grep -q '区切りは挿入されない' docs/spec/backend.md`
- [ ] `! grep -q '改行を挟んで' docs/spec/backend.md`
- [ ] `./tests/run.sh`

## Notes

- 票31（`subcon log` 新設）と並行実施する。票31の受け入れテスト（`logcmd` グループ）が未実装で失敗しても、それは本票の責ではない。本票の担当範囲（上記 grep 群）が全て通り、既存テストに新規の失敗が無ければ done と報告してよい。全体の最終確認は監督側で行う。
- `subcon log` のコマンド一覧行（項目1）は票31の実装仕様として先行して記載するもので、正しい。
- 文面の細部（接続詞や句読点）は任せるが、Acceptance の grep に使う語句は上記のとおり正確に含めること。
