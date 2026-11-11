# 34-driver-selection

## Goal

ドライバ層分離の第二段（設計は ../driver-layer.md）。ドライバの選択（`--driver` / `SUBCON_DRIVER`、既定 `agy`）を CLI からジョブ実行まで通し、事前確認・既定モデル・表示名解決をドライバの補助サブコマンド経由に一般化する。あわせて票33 の残件である `SUBCON_SETTINGS` の残存参照（`runners/container`、`ci/run-job.sh`、仕様書、定数）を掃除する。container / ci ランナーで agy 以外のドライバを使うのは後続票の担当で、本票では明示エラーで止める。

## Files

- bin/subcon
- lib/common.sh
- lib/job.sh
- lib/query.sh
- lib/manage.sh
- drivers/agy
- runners/container
- ci/run-job.sh
- docs/spec/runner.md

## Interface

### ドライバの補助サブコマンド（契約）

- `drivers/<name>` の第 1 引数が `preflight` / `models` / `default-model` のいずれかなら補助動作、それ以外はジョブディレクトリのパスとして本実行（現行どおり）。
- `preflight`: そのドライバで実行可能なら終了コード 0 で無出力。不可なら理由を標準エラーに出して終了コード 1。
- `models`: モデル一覧を `id<TAB>表示名` の TSV で標準出力へ。
- `default-model`: 既定モデル ID を 1 行で標準出力へ。

### drivers/agy

- `preflight`: 現行 `lib/common.sh` の `require_agy` と同じ判定（PATH に `agy`、無ければ `~/.local/bin/agy` を PATH に足して解決）。不在なら標準エラーに現行の die と同じ文言 `agy not found: install agy and make sure it is on PATH or at ~/.local/bin/agy` を出して 1。
- `models`: 解決した agy バイナリの `models` 出力をそのまま出す。
- `default-model`: `gemini-3.8-flash-medium` を出す。
- 本実行（ジョブディレクトリ引数）は現行どおり変更しない。

### lib/common.sh

- `driver_path <name>`: `$SUBCON_ROOT/drivers/<name>` が実行可能ファイルならそのパスを標準出力へ、無ければ return 1。
- `require_driver <name>`: `driver_path` が無ければ `die "unknown driver: <name>"`。ドライバの `preflight` を実行し（標準エラーはそのまま流す）、失敗したら `die "driver preflight failed: <name>"`。
- `default_model <driver>`: `SUBCON_MODEL` が設定されていればその値、無ければ `drivers/<driver> default-model` の出力。
- `model_name <model> <driver>`: `drivers/<driver> models` の TSV から、現行と同じ awk（末尾の ` (…)` を除去）で表示名を引く。
- `cmd_trailer`: `--model` に加えて `--driver` を受理する（ドライバの初期値は `SUBCON_DRIVER`、無ければ `agy`）。`require_driver` → `default_model <driver>` → `model_name <model> <driver>` の順で解決し、未知モデルなら `die "unknown model: <model> (see: <driver> models)"`。
- 削除するもの（いずれも本票の変更で参照が消えるため）: `SUBCON_SETTINGS` 定数、`SUBCON_DEFAULT_MODEL` 定数、`require_agy`、`agy_bin`。削除後に参照が残る場合は消さず、その旨を `design_questions` に記録すること。
- `agy_auth_mode` / `warn_consumer_auth` は残す（呼び出し側でドライバが agy のときだけ使う）。

### lib/job.sh

- `job_create`: 引数の末尾に `<driver>` を追加する（8 番目、`<from-job-dir>` の後）。空なら `agy` として扱い、`meta.json` の `driver` はこの値を使う（票33 で入れた固定値 `agy` を置き換える）。
- `cmd_submit`:
  - `--driver` オプションを追加する（初期値は `SUBCON_DRIVER`、無ければ `agy`）。`--runner` 等と同型の解析。
  - 現行冒頭の `require_agy` / `warn_consumer_auth` は置き換える: 引数解析の後に `require_driver "$driver"` を呼び、ドライバが `agy` のときだけ `warn_consumer_auth` を呼ぶ。
  - モデルが `--model` でも `SUBCON_MODEL` でも指定されていない場合は `default_model "$driver"` で解決する。
  - ランナーが `container` または `ci` でドライバが `agy` でない場合は `die "the <runner> runner supports the agy driver only"` で止める。この検査は `require_container` / `require_ci` より前に行う。
  - `job_create` へドライバを渡す。
- `cmd_resume`:
  - 現行冒頭の `require_agy` / `warn_consumer_auth` は置き換える: 引数解析の後に再開元ジョブの `meta.json` からドライバを読み（`jq -r '.driver // "agy"'`）、`require_driver` と（agy のときだけ）警告を行い、`job_create` へそのドライバを渡す。

### lib/query.sh

- `cmd_run`: 透過オプション（`--runner|--model|--timeout`）に `--driver` を追加する。

### lib/manage.sh

- `cmd_commit`: 対象ジョブの `meta.json` からドライバとモデルを読み、`require_driver "<driver>"` に置き換える（現行の `require_agy`）。実装者名の解決は `model_name "<model>" "<driver>"` を使う。
- `cmd_reject`: 同様に `meta.json` のドライバで `require_driver` し、再 submit の引数に `--driver "$effective_driver"` を追加する（`effective_runner` / `effective_model` と同じ引き方で meta から読む）。

### bin/subcon

- usage の `submit` と `run` の行に `[--driver D]` を追加する。他の行は変更しない。

### SUBCON_SETTINGS の掃除

- `runners/container`: `docker run` の引数から `-e SUBCON_SETTINGS` を除去する。
- `ci/run-job.sh`: `export SUBCON_SETTINGS=...` の行を除去し、手順 3 のコメントからも `SUBCON_SETTINGS` を除く。
- `docs/spec/runner.md`: 契約環境変数の一覧表から `SUBCON_SETTINGS` の行を除去する。

## Acceptance

- [ ] `./tests/run.sh driver`
- [ ] `./tests/run.sh`

## Notes

- 既存テストは変更しない。監督側が `driver` グループのテストを追加済みで、`test_container_entry_uses_driver` の `SUBCON_SETTINGS` フィクスチャ行も監督側で除去済み（entry がドライバ経由で動き、共有 env に `SUBCON_SETTINGS` が無くても通ることの確認を兼ねる）。
- 既存の事前確認テスト（`preflight` グループ）は、agy 不在時の文言と「ジョブを作らない」挙動がドライバ経由でも保たれることを見るものとして扱う。落ちた場合は自票の範囲で直すこと。
- container / ci での agy 以外のドライバ対応（イメージへの同梱、ワークフローへの引き回し）は本票の範囲外。ガードの明示エラーのみを入れる。
- `drivers/claude` は票35。本票で先取りしない。
