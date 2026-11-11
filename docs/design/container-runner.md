# container ランナー設計（フェーズ 2）

`docs/design/v2.md` の「ランナー契約」の container 節を具体化する。目的は local ランナーの残存問題（agy のサンドボックス外実行を止められず、Flash がリポジトリ外にも書けうる）を、使い捨てコンテナによるファイルシステム隔離で塞ぐこと。

## 形

- `runners/container`（ホスト側、bash）: ジョブディレクトリを受け取り、コンテナを 1 つ起動して agy を実行させる。ランナー契約（引数・環境変数・`agy.json` の責務・終了コード）は local と同じ
- `runners/container-entry.sh`（コンテナ内）: コンテナのエントリポイント。`work/` をカレントにして agy を実行し、`agy.stream` の生成と `agy.json` の抽出を行う（local ランナーの agy 実行部分とほぼ同じ処理。重複は既知で、将来 `runners/` の共通部品に寄せる）
- `container/Containerfile`: 実行イメージの定義。**agy バイナリは同梱しない**。ビルド時に公式配布元から取得する（利用者自身がビルドする形にし、こちらがバイナリを再配布しない）

## 実行の流れ

1. `lib/job.sh` が通常どおり worktree（`work/`）と `prompt.txt` を用意する（ホスト側、local と同じ）
2. `runners/container` がスキーマファイルを `$job_dir/schema.json` にコピーする（コンテナ内パスを `/job/schema.json` に固定するため）
3. エンジンでコンテナを起動する:
   - マウント: `$job_dir/work` → `/work`（rw）、`$job_dir` → `/job`（rw）、`$HOME/.gemini` → `/home/runner/.gemini`（rw、認証情報と会話 DB）
   - 環境変数: `HOME=/home/runner`、`SUBCON_PROMPT_FILE=/job/prompt.txt`、`SUBCON_SCHEMA=/job/schema.json`、`SUBCON_SETTINGS` / `SUBCON_MODEL` / `SUBCON_TIMEOUT` / `SUBCON_CONVERSATION` はホストの値をそのまま渡す
   - `--workdir /work`、`--rm`、`--name subcon-<ジョブID>`、`--user <ホストの uid:gid>`（worktree のファイル所有者をホスト側と一致させる）
4. コンテナ内では `container-entry.sh` が agy を実行し、`/job/agy.stream` と `/job/agy.json` を書く
5. 終了コードは agy のものをそのまま返す。以後の後処理（チェック・パッチ生成・`result.json`）はホスト側が local と共通に行う

## エンジン

- 解決順: `SUBCON_CONTAINER_ENGINE` 環境変数 → `docker` → `podman`。どちらも無ければランナーは 1 で終わる（事前確認の改善は票17）
- イメージ名は `SUBCON_CONTAINER_IMAGE` で差し替え可（既定 `subcon-runner:latest`）。イメージの自動ビルドはしない（無い場合はエンジンのエラーがそのままジョブの失敗になる。組み立て手順は README に書く）

## 認証情報の渡し方

- 消費者ログイン: `$HOME/.gemini` のマウントで渡る。会話 DB も同じ場所なので、同一ホストでの `resume` が成立する
- API キー: ホストの環境変数 `GEMINI_API_KEY` が設定されていれば `-e GEMINI_API_KEY` でコンテナに渡す（ファイルには書かない）。settings.json の `modelProvider` はマウントされた `.gemini` 側の設定がそのまま効く

## 隔離の範囲と限界

- 塞げる: リポジトリ（`work/`）とジョブディレクトリと `.gemini` 以外への書き込み。プロセスの隔離
- 塞げない: ネットワーク（agy が Google の API に到達する必要があるため既定で有効）。外向き通信の制限は将来課題
- ホスト側ランナーが kill された場合にコンテナが残らないよう、`runners/container` は trap で `engine rm -f <name>` を呼ぶ（discard 時の後片付け）

## テスト方針

- 本物のエンジンと本物の agy は使わない（repo の既存方針）。`tests/fake-engine` が `docker` の顔をして `run` の引数を解釈し、マウントをパスの読み替えとしてエントリをホスト上で実行する。検証するのは契約の形（マウント・環境変数・終了コード・`agy.json` の生成）
- 実エンジンでの煙テスト（イメージのビルドと実ジョブ 1 件）は手動検証として残し、実施したら結果をこの doc に追記する

## 実装状況（2026-11-11）

- 票16（ランナー本体）・票17（事前確認）とも実装済み。全テスト 82 件通過（fake engine による契約検証を含む）
- 実エンジンでの煙テストは Mac mini（Apple Silicon、colima の docker）で実施済み（2026-11-11）。実 Containerfile のビルド成功（イメージ内 agy 1.5.5 を確認）、fake-agy に差し替えた変種イメージで `--runner container` の実ジョブが finished / done、パッチ生成まで確認。検証中に見つけた不具合: エントリスクリプトのモードがソース側のファイルモード依存で、環境によっては実行ユーザー（ホスト uid）が読めず起動に失敗する → Containerfile で `chmod 755` を明示するよう修正済み
- この VM では実エンジン実行は不可（2026-11-11 に試行）: docker / podman が無く、mise 経由は podman-remote と nerdctl の CLI のみ。nerdctl-full で containerd 起動まではできたが、レジストリ CDN への TLS タイムアウトと runc の setns 拒否（`operation not permitted`）でコンテナを実行できない
- コンテナ内の git は現行のマウント構成では使えない（2026-11-11 に Mac mini で検証済み）。worktree の `.git` ファイルが指すホスト側 gitdir がマウント外のため `fatal: not a git repository: .../.git/worktrees/<name>` になる。ファイル編集は問題ないが、コンテナ内で git を実行して失敗終了するエージェントはジョブごと落ちる（fake-agy の commit モードで実ジョブが exit 128 で失敗することを確認。ホスト側のパッチ生成・チェックは無事）
- 対処の検証結果: 本体 `.git` を同じ絶対パスにマウントすれば gitdir は解決するが、(1) rw マウントはホストのリポジトリの `.git`（config・hooks を含む）への書き込みをコンテナに許すことになり隔離が崩れる、(2) ro マウントでは `git status` は動くが `git add` 以後の書き込み系が index.lock で失敗する、(3) macOS（virtiofs）ではマウント内のファイルが root 所有に見えるため、どちらの場合も `safe.directory` の設定が別途必要
- 修正済み（票18）: container ジョブでは worktree の代わりにジョブ内へローカル clone を作り、`work/` の中に実体の `.git` を持たせた。あわせてイメージ側に `safe.directory`（`/work` のみ）を入れた。Mac mini の実機で再検証済み: commit モードの実ジョブが finished / done になり、コンテナ内のコミットをホスト側が `checks.committed: true` として検出できた（修正前は exit 128 でジョブ失敗）

## 票への分割

| 票 | 内容 | 担当 | 触るファイル |
| --- | --- | --- | --- |
| 16 | container ランナー本体（ランナー・エントリ・Containerfile・fake engine テスト） | Flash | `runners/container` `runners/container-entry.sh` `container/Containerfile` |
| 17 | container の事前確認（`--runner container` の submit 時にエンジンとイメージの有無を確認し、無ければジョブを作らず終了コード 1） | Flash | `lib/common.sh` `lib/job.sh` |

## 前提の確認結果

- agy は Linux で動く（この VM で稼働中）。公式インストーラは `curl -fsSL https://antigravity.google/cli/install.sh | bash` で、バイナリは `~/.local/bin/agy` に入る。要件は glibc 2.28 以上（Debian bookworm で可、musl の Alpine は不可）
- 認証情報は `$HOME/.gemini/antigravity-cli/` 配下のファイル群なので、ディレクトリマウントで渡せる
