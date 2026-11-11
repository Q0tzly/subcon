# CI ランナー設計ドラフト（フェーズ 3）

remote ランナー（ssh 先で実行）の構想を、GitHub Actions の self-hosted ランナーで票を実行する形に置き換える設計。v1（票19〜21＋票22の tar 所有者修正）は実装済みで、全テスト 92 件通過（fake-gh による契約検証を含む）。

実地確認（2026-11-11、Mac mini）: self-hosted ランナー（ラベル `subcon`）を登録・起動し、実ワークフローを複数回実行した。dispatch → run-name 相関 → mini でのチェックアウトと `ci/run-job.sh` 実行 → artifact のアップロード／回収 → パッチ計算まで一貫して動作。1 回目の実行で、macOS 側 tarball の所有者（uid 501）をホストで復元できない問題が見つかり、票22で修正済み。agy のサインイン後は実ジョブ（票03、gemini-3.8-flash-medium）が status done で完了し、agy.json のレポート回収まで確認した。

前提（agy の認証）: macOS で対話ログインしたトークンはキーチェーンに入り、ランナー等の非対話文脈からは読めない。SSH 文脈でログインし直してファイル保存（`~/.gemini/antigravity-cli/antigravity-oauth-token`）に切り替える必要がある（agy は SSH セッションを検出するとファイル保存を使う）。

## なぜ CI か

- agy の公式な位置づけでは、本人のスクリプト／CI ワークフローから `agy -p` を呼ぶ形が「意図した使い方」とされている。実行を本人の CI に寄せることで、エージェントが対話的に agy を駆動する形から離れられる
- self-hosted なら認証情報が本人のマシンの外に出ない。キュー・実行履歴・ログ保持は Actions の標準機能で賄える
- 常駐マシン（Mac mini 等）に self-hosted ランナーを置けば、上位のマシンの電源・ネットに左右されずにジョブを回せる

## 形

ランナー契約の拡張として実装する。現行契約は「ランナーは agy を実行して `agy.json` を書く。パッチとチェックはホスト側が `work/` から作る」。CI では作業がリモートで起きるため、リモート系ランナーの責務を「リモートで agy を実行し、変更後の `work/` の中身と `agy.json` をホストのジョブディレクトリに戻す」まで広げる。ホスト側の後処理（チェック・パッチ生成・`result.json`）は local / container と共通のままにできる。

- `runners/ci`（ホスト側）: `gh workflow run` でワークフローを起動し、ジョブ ID で相関を取りながら完了を待ち、artifact（変更後 worktree の tar、`agy.json`、`agy.stream`）をダウンロードしてジョブディレクトリに展開する。終了コードはワークフローの結論から決める
- ワークフローテンプレート（`.github/workflows/subcon-job.yml`）: 利用者のリポジトリに置く。`run-name` にジョブ ID を含め、入力は `job` / `ticket` / `base` の 3 つ
- ワークフロー側の実行: base を checkout し、票からプロンプトを組み立てて agy を実行する（`runners/local` 相当の処理）。実行環境は self-hosted マシン上の直接実行か、container ランナーの併用かを選べるようにする

## 論点

- プロンプトの組み立て場所: ホスト側の `prompt.txt` はサイズが大きく workflow input に載せにくい。ワークフロー側で票から組み立てる（subcon 自身のリポジトリでは自前の `lib/` を使える。他リポジトリ向けには、固定バージョンの subcon を checkout して使う形をテンプレートに含める）
- resume: 会話 DB は実行したマシンに残るため、再開は同じ self-hosted マシンに dispatch する必要がある。v1 は単一マシン前提とし、`meta.json` に実行マシン（ランナーラベル）を記録する
- タイムアウトと打ち切り: ホスト側ランナー（`runners/ci`）がポーリングを担うので `pid` と消失検出の意味は保てる。discard 時は trap で `gh run cancel` を試みる
- 認証: 送信側マシンに `gh` の認証が必要。実行側は self-hosted マシン上の agy ログイン（または API キー）をそのまま使う。GitHub ホスト型ランナーは認証情報の持ち込みが規約・安全の両面で問題になるため対象外

## 段階

1. v1: subcon 自身のリポジトリで dogfooding（self-hosted 1 台、直接実行）
2. テンプレート化と他リポジトリ対応（subcon の固定バージョン取得、container 併用）
3. 複数マシン対応（ランナーラベルの選択と resume の追随）

## v1 の契約（票19・20）

- ワークフローは `.github/workflows/subcon-job.yml`。`workflow_dispatch` の入力は `job` / `ticket` / `base` / `model` / `timeout` の 5 つ。`run-name` は `subcon <job>` とし、`runs-on` は `[self-hosted, subcon]`（専用マシンに付けたラベル）
- CI 側の実行は `ci/run-job.sh` が担う。環境変数 `SUBCON_CI_JOB` / `SUBCON_CI_TICKET` / `SUBCON_CI_BASE` / `SUBCON_CI_MODEL` / `SUBCON_CI_TIMEOUT` を受け、`lib/common.sh` の定数（スキーマ・前文・設定）を使う。作業場所は `${RUNNER_TEMP}/subcon-<job>/` で、中に `job/`（ticket.md、prompt.txt、work/ の clone）と `artifact/` を作る。`runners/local` をその job ディレクトリで実行し、成否によらず成果物をまとめる
- artifact の中身（名前は `subcon-artifact` で固定）: `work.tar.gz`（`work/` をトップに含む tar）、`agy.json`（あれば）、`agy.stream`（あれば）
- ホスト側の `runners/ci` は `gh` で dispatch し、`run-name` と開始時刻で run を特定して完了を待つ（ジョブの timeout ＋ 120 秒で打ち切り、`gh run cancel` を試みる）。完了したら結論によらず artifact をダウンロードし、`work.tar.gz` をジョブの `work/` に戻し、`agy.json` / `agy.stream` をジョブディレクトリに置く。終了コードは結論が success のとき 0、それ以外は 1
- v1 では ci ジョブの resume は未対応（会話は CI マシン側にしか無く、ホスト側の前回パッチ引き継ぎとも噛み合わないため）。必要になったら段階 3 で扱う
