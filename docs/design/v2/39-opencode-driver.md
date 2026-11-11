# 39-opencode-driver

## Goal

`drivers/opencode` を新設し、OpenCode（`opencode run`）を実装役ドライバとして使えるようにする（フェーズ6 後続、設計は ../phase6-followups.md の改訂後の決定 A と Q2 / Q3 / Q7 / Q8）。あわせてホスト側の小さな追従 2 件（`model_name` のフォールバック、報告なし完了の終了コード）を行う。

## Files

- drivers/opencode（新規）
- lib/common.sh
- lib/query.sh
- docs/spec/cli.md
- README.md

## Interface

### drivers/opencode — 基本契約

`drivers/agy` / `drivers/claude` と同じ契約（引数なし＝本実行（引数 $1 はジョブディレクトリ）、`preflight` / `models` / `default-model` の補助サブコマンド）。bash 3.2 で動くこと。

- `preflight`: `opencode` が PATH に無ければ stderr に `opencode not found: install OpenCode and make sure it is on PATH` を出して 1。あれば無言で 0。**実接続の確認（API 呼び出し）は行わない**（Q8）。
- `models`: 次の 2 行（TSV）を出す:
  - `sakura/preview/Kimi-K2.7-Code` → `Kimi K2.7 Code (Sakura)`
  - `sakura/gpt-oss-120b` → `gpt-oss-120b (Sakura)`
- `default-model`: `${SUBCON_OPENCODE_DEFAULT_MODEL:-sakura/preview/Kimi-K2.7-Code}` を出す（Q7）。

### drivers/opencode — 本実行

作業ディレクトリ（cwd = `work/`）で実行される前提。環境変数は契約どおり（`SUBCON_PROMPT_FILE` / `SUBCON_SCHEMA` / `SUBCON_JOB_MODEL` / `SUBCON_TIMEOUT` / `SUBCON_CONVERSATION`）。

1. **プロンプト拡張**: `SUBCON_PROMPT_FILE` の内容の末尾に、報告指示節を足したものを `$job_dir/prompt.driver.txt` に書く。報告指示節は英語で、内容は: 「最終メッセージは次の JSON Schema に沿う JSON オブジェクト**のみ**とすること（前後に文章やコードフェンスを付けない）」＋ `SUBCON_SCHEMA` の中身を verbatim で埋め込み。opencode には拡張した方を渡す。
2. **起動**: `opencode run --format json --dangerously-skip-permissions -m "$SUBCON_JOB_MODEL" [--session "$SUBCON_CONVERSATION"] <拡張プロンプト>`。プロンプトは位置引数で渡す。全体を `timeout "$SUBCON_TIMEOUT"` で包む（`gtimeout` へのフォールバックは drivers/claude と同じ流儀）。標準出力はパイプせず **`$job_dir/agy.stream` へ直接リダイレクト**する（Q2。バッファリングでイベント到着が遅れないように）。
3. **起動ウォッチドッグ**（Q8）: 起動後、`agy.stream` に最初の `step_start` イベントが現れるかプロセスが終了するまで監視する。**`SUBCON_OPENCODE_WATCHDOG` 秒（未設定なら 20）** 経っても `step_start` が無くプロセスが生きていたら、そのプロセスを kill して **1 回だけ**再起動する（この時点ではモデル未稼働で副作用・課金は無い）。再起動後も同じ監視をし、2 回目の起動が止まった場合はそのまま失敗として扱う（3 回目は無い）。監視は stream ファイルの内容で行い、追加の API 呼び出しはしない。
4. **会話 ID の回収**（Q2、ベストエフォート）: 終了後、`agy.stream` の最初のイベントから sessionID を取る（`.sessionID // .part.sessionID` の順で探す）。取れなければ `conversation_id` は付けない。
5. **usage の合算**（Q3）: 全 `step_finish` イベントの `.part.tokens` を合算する。写像: `input` → `input_tokens`、`output` → `output_tokens`、**`total` → `total_tokens`**、`reasoning` → `thinking_tokens`、`cache.read` → `cache_read_tokens`。**`cache.write` は捨てる**（drivers/claude が cache_creation を捨てるのと揃える）。`duration_seconds` はドライバ側で測った実行時間（再起動した場合は合計）。**`cost_usd` は付けない**（Q4）。
6. **報告の抽出と検証**（Q1）: 最後の `text` イベントの `.part.text` に対して次の順で JSON オブジェクトの抽出を試みる:
   a. テキスト全体を JSON として解釈する。
   b. ```` ```json ```` コードフェンスの中身を取り出して解釈する。
   c. 最初の `{` から最後の `}` までの部分文字列を取り出して解釈する。
   抽出できたら検証する: 必須キー 6 つ（`status`, `summary`, `files_changed`, `commands_run`, `design_questions`, `issues_found`）をすべて持ち、`status` が `done` / `partial` / `blocked` のいずれかであること。検証を通ればそれを `structured_output` とする。
7. **結果の書き出し**（`$job_dir/agy.json`）と終了コード:
   - opencode の終了コードが 0 で抽出・検証が通った: `{status: "SUCCESS", conversation_id, duration_seconds, usage, structured_output}` を書き、終了コード 0。
   - opencode の終了コードが 0 だが抽出・検証が通らなかった: **ERROR は合成せず**、`structured_output` を含まない `{status: "SUCCESS", conversation_id, duration_seconds, usage}` を書き、終了コード 0（上位は `status: null` の完了として扱う。決定 A 改訂）。
   - opencode の終了コードが非 0: `{status: "ERROR", conversation_id（回収できた場合）, error: "opencode exited without a result"}` を書き、終了コード 1（drivers/claude の nojson 経路と同じ流儀）。

### lib/common.sh — model_name のフォールバック（Q7）

- `model_name <model> <driver>`: ドライバの `models` 出力に該当モデルが無い場合、現行は空を返し呼び出し側（`cmd_trailer`、`subcon commit` の実装役名解決）が `unknown model` で die する。これを、**該当が無ければモデル ID 自体を返す**ように変える。登録済みモデルの表示名解決は無変更。opencode のように利用者が任意の `provider/model` を持ち込むドライバでも trailer / commit が詰まらないようにするため。

### lib/query.sh — exit_code_for の追従（Q1）

- `state == "finished"` で `.status == null`（報告なし完了）のジョブを、終了コード **2** として扱う。現行の優先順位（failed=4、checks 違反=3、partial/blocked=2）は維持し、null の扱いは「state が finished のときだけ」2 にする（実行中・待機中ジョブの status は元々 null で、そちらは従来どおり 0）。

### docs/spec/cli.md

- 終了コード表のコード 2 の意味に「または報告なし（`status: null`）で完了」を加える。
- `--driver D` の説明に opencode を加える: `opencode` ドライバも選択でき、モデルは `provider/model` 形式で任意に指定できる（既定はドライバの `default-model`）。

### README.md

- 「ドライバ」節の一覧に opencode を加える（OpenCode CLI が必要。モデルは `provider/model` 形式。プロバイダ設定（opencode.json）は利用者側で用意する）。

## Acceptance

- [ ] `./tests/run.sh driver`
- [ ] `./tests/run.sh query`
- [ ] `./tests/run.sh`
- [ ] `test -x drivers/opencode`

## Notes

- 本票の実装役は Haiku（subcon シム経由。尽きたら Flash）。
- テストは監督側が用意済み（`tests/run.sh` の driver グループと `tests/fake-opencode` フィクスチャ）。テストファイルとフィクスチャは変更しないこと。
- 実機確認（mini で Sakura の実モデルを通す）は監督側が実施する。本票の受け入れには含めない（この VM では `opencode run` が init 直後で止まる環境事象が確認済みで、ウォッチドッグはその対策でもある）。
- プロバイダ設定ファイル（opencode.json）はドライバの管理対象にしない（認証・設定は利用者側。agy / claude と同じ分界）。
