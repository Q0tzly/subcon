# reviewer（読み取り専用のレビュー役）

状態: 草案 v2（2026-11-15）。方向は決定済み。v1 草案を Hydrogen（agy、読み取り専用）にレビューさせ、
S1×5・S2×9・S3×2 の指摘を仕分けて反映した。

## 目的

subcon は「実装役に票を渡し、上位が検収する」仕組みで、レビューを機械に任せる経路がない。
上位の運用方針は「別系統のモデルに読み取り専用でレビューさせる」だが、今は `agy` を手で叩いている。
これを subcon の正規の経路にする。

役割分担の既定:

- 実装役 = Claude Haiku 5.5（`SUBCON_DRIVER=claude`。コードは変えない）
- レビュー役 = Gemini 4 Hydrogen（agy）
- 検収・コミット = 上位。レビュー役の指摘は鵜呑みにせず上位が仕分ける

## 決定済み

1. 対象は **ジョブの patch** と **任意の対象**（設計 doc・票）の両方。
2. レビューは **記録するだけ**で `subcon commit` を止めない。`commit` はレビュー済みなら
   `Reviewed-By` にレビュー役のモデルを自動で足す。

## コマンド

```sh
subcon review [--driver D] [--model M] [--timeout T] <job-id>
subcon review [--driver D] [--model M] [--timeout T] --target <path>... [--brief <file>]
subcon reviews [<job-id>]
```

- `<job-id>`: 状態が `finished` のジョブ。`patch.diff` を、票・`checks`・実装役の `report` に照らして読む。
  ジョブを実装したランナーは問わない（`review` 自体は常にローカルで動く）。
- `--target`: リポジトリ内のファイル（複数可）を **発行時の `HEAD`** で読む。検証は票の `## Files` と同じ
  （`/` 始まり・`.` `..`・glob 文字を拒否、`git cat-file -e HEAD:<path>` で存在確認、ディレクトリ不可）。
  `--brief` は観点（何を見てほしいか）のファイル。未指定なら汎用の観点。
  未コミットの作業ツリーは読めない（先にコミットする。v1 の制約）。
- 既定のドライバは `SUBCON_REVIEW_DRIVER`（既定 `agy`）。モデルは `--model` > `SUBCON_REVIEW_MODEL` >
  （ドライバが `agy` なら `gemini-4-hydrogen-high`、それ以外はそのドライバの `default-model`）。
  実装役の `SUBCON_DRIVER` / `--model` とは独立。
- stdout は JSON（`{"id": "<review-id>", "verdict": …, "s1": n, "s2": n, "s3": n, "path": "<保存先>"}`）、
  進捗とエラーは stderr。存在しない・未完了のジョブ、使い方の誤りは終了コード `1`。
- 終了コード: `0` 完了、`2` S1 の指摘あり、`4` 失敗（タイムアウト含む。ジョブと同じ扱い）。
  `5` は `wait` 専用なので使わない。
- `reviews [<job-id>]`: 現在のリポジトリのレビューを新しい順に JSON 配列で出す
  （`<job-id>` で絞る）。各要素は保存先のメタ（下記）に `verdict` と件数を足したもの。

## 読み取り専用の担保

実装ジョブの `work/` は `job_finalize` で消えるので使えない。レビューは常に **新しい使い捨てコピー**で行う。

1. 一時ディレクトリに `git clone --local --no-checkout` で対象リポジトリを複製し、
   ジョブ対象なら `base`、`--target` なら `HEAD` をチェックアウトする。親の `.git`
   （オブジェクト・refs・config）は共有しない（`git worktree` は使わない）。
2. ジョブ対象は `patch.diff`（非空なら）を `git apply` し、**一時コミット**を作る。
   これでレビュー役が読む状態がコミットに固定され、事後検査が成り立つ。
3. レビュー役を起動する。起動中の作業ディレクトリはこの複製。
4. 終了後に、複製で `git rev-parse HEAD` が一時コミットのままで `git status --porcelain` が空であることを確かめる。
   崩れていれば結果を捨て、`failed`（`error: reviewer modified files`）にする。
5. `EXIT INT TERM HUP` の trap で複製を必ず消す。

ドライバ側（`SUBCON_ROLE=review` のとき。複製の外・親リポジトリへの書き込みは、そもそもツールを与えないことで防ぐ）:

- **agy**: `allow` から `command(*)` を外す。許可は `read_file(<複製>)` と、フラグで実行・書き込みができない
  コマンド（`cat` `ls` `head` `tail` `grep` `wc`）に限り、`git` `gh` `sudo` `rm` は deny。規則は語の前方一致なので、
  `sed`（`-i` `w`）・`rg`（`--pre`）・`fd`（`-x`）は許可しない（Hydrogen のレビューで指摘、2026-11-15）。
  編集ツール（`write_file` `edit_file` `write_to_file` `replace_file_content` `multi_replace_file_content`）は deny に入れる。
  実機の確認（2026-11-15）: accept-edits を外しただけでは `write_file` が通ってファイルが作られた。
  deny に入れると `write_file` は拒否され、`git commit` と `rm` も拒否された。ツール名の網羅は保証できないので、
  複製の事後検査（上の手順 4）が最後の砦になる。`cat x > y` のようなリダイレクトは複製の中なら事後検査が、
  外なら agy の `--sandbox` が止める前提（未検証）。
  実機の確認（2026-11-15）: `--disable-slash-commands` を付けると`--mode plan` は効かない（警告が出る）ので、
  `plan` には頼らない。
- **claude**: `--permission-mode dontAsk --allowedTools "Read,Grep,Glob"` に加え、
  `--disallowedTools "Edit,Write,Bash,NotebookEdit,WebFetch,WebSearch"`（`dontAsk` は確認が要るものを拒否するだけで、
  利用者の設定の allow 規則が有効なら通りうるため）。
  `SUBCON_CLAUDE_MCP_CONFIG` と `SUBCON_CONVERSATION` は review では無視し、MCP は空に固定する。
  実機の確認（2026-11-15、claude-haiku-5-5）: `--json-schema` と併用して完走し、`structured_output` が返った。
  Write と Bash の試行は `permission_denials` に記録されて拒否され、ファイルは作られなかった。
- テストの再実行はしない（検収と同じく上位の仕事）。
- **opencode**: v1 は未対応。`SUBCON_ROLE=review` ならエラーにする。

## ドライバへの渡し方（実装ジョブの成果物を壊さない）

ドライバは第 1 引数のディレクトリ直下に `agy.stream` と `agy.json` を書く。
`jobs/<id>` をそのまま渡すと実装ジョブの成果物を上書きするので、**レビュー専用の一時ディレクトリ**を渡す。

- 一時ディレクトリに `meta.json`（最低限 `repo`。agy の `read_file` 許可の解決に使われる）とプロンプトを置く。
- 終了後に `agy.json` から `structured_output` と `usage`・`duration_seconds`・`cost_usd`・`error` を取り出し、
  下の保存先へ移す。`agy.stream` は `review-<n>.stream` に移す。

## プロンプトの入力

- ジョブ対象: 票の全文（`## Goal` `## Files` `## Interface` `## Acceptance` `## Notes`）、`checks`
  （`files_changed`・範囲外の変更・コミットの有無）、実装役の `report`（`summary` `commands_run`
  `design_questions` `issues_found`）、`patch.diff`。
- `--target`: 対象ファイルの一覧と `--brief`。
- 共通: S1（誤り・保証の穴）／S2（弱点）／S3（軽微）の定義、「読んでいないものは `unverified` に書く」、
  「ファイルを変更しない」。文面は fabric の Hydrogen レビュー依頼を雛形にする。

## 出力

`schema/review.schema.json`（新規）:

```json
{
  "verdict": "approve | changes | reject",
  "summary": "string",
  "findings": [
    {
      "severity": "S1 | S2 | S3",
      "file": "string",
      "line": 0,
      "summary": "string",
      "failure_scenario": "string",
      "fix": "string"
    }
  ],
  "unverified": ["string"]
}
```

- `line` は整数（0 以上）。0 はファイル全体・行が特定できない指摘。全項目 required、追加項目なし。
- スキーマで表せない整合は、検証関数（票 58）が結果の受け取り時に確かめる:
  `findings` が空なら `verdict` は `approve`、S1 が 1 件でもあれば `approve` ではない。
  破れていれば `failed`（`error: inconsistent verdict`）。
- `unverified` は必須。読めなかった点を明示させ、空の「全部読んだ」を避ける。

## 保存

- ジョブ対象: `${SUBCON_STATE}/jobs/<id>/review-<n>.json`（結果）、`review-<n>.meta.json`
  （`v` `id` `job_id` `driver` `model` `created_at` `duration_seconds` `cost_usd` `usage` `error`）、
  `review-<n>.stream`。`n` は既存の `review-*.meta.json` の数値最大 + 1 で、並行する review が同じ番号を取らないよう
  プレースホルダの meta を noclobber で先に作って確保する（解放されなかった番号は「中断」として残る）。失敗したレビューも
  `meta.json` に `error` を残し、`review-<n>.json` は作らない（`n` は進める）。最新 = `review-<n>.json` が
  ある最大の `n`（文字列の並びではなく数値で比べる）。
- `--target`: `${SUBCON_STATE}/reviews/<review-id>/` に同じ名前（`review.json` `review.meta.json`
  `review.stream`）で置き、meta に `repo` `head` `targets` `brief` を足す。
- `history.jsonl` に 1 行追記（既存の規約どおり `v: 1` と `type`）:
  `{"v":1,"type":"review","id":<review-id>,"target_type":"job|target","job_id":…,"repo":…,
  "created_at":…,"driver":…,"model":…,"verdict":…,"s1":n,"s2":n,"s3":n,"duration_s":…,"cost_usd":…,"tokens":…}`。
- v1 では `stats` と月次の予算（`history_month_usage`）にレビューを含めない（`type: "review"` の行は
  既存の集計に無視される）。`by_role` は必要になってから足す。

## commit との連携

`subcon commit <id>` は最新のレビュー（上の定義）があれば、trailer に次を足す:

```
Reviewed-By: <レビュー役のモデル名> <アドレス>
```

- `verdict` が `reject` のときは足さない（承認したように見えるため）。`approve` と `changes` は足す。
- 既存の `Reviewed-By: $SUBCON_REVIEWER`（上位）は残す。つまり 2 行になる。
- モデル名は `model_name`（レビュー役のドライバの `models`）で引く。引けなければモデル ID をそのまま使い、
  レビュー役のドライバの `preflight` は要求しない（別マシンで作ったレビューでも commit できる）。
  アドレスは既存の `coauthor_email()` を使う（モデル名の先頭で分岐。`SUBCON_COAUTHOR_EMAIL` の優先関係もそのまま）。
  新しい環境変数は足さない。
- 最新のレビューに S1 があるときは stderr に
  「最新のレビュー（review-N）に S1 の指摘が X 件あります」と 1 行出す。解消済みかどうかは記録しない
  （上位が仕分け済みかは subcon には分からない）。commit は止めない。

## 認証と規約

agy の消費者ログインを使う場合の警告は、実装役と同じく `review` でも出す
（`SUBCON_NO_AUTH_WARNING=1` で抑止）。claude をレビュー役にする場合は `claude auth login` か API キーが必要。

## 作業票

依存順: `58 → 59 → 60 → (61 / 62 は並行可) → 63`。

| # | 中身 | 触る場所 | 担当 |
| --- | --- | --- | --- |
| 58 | `schema/review.schema.json`、レビュー用プロンプト、`lib/review.sh`（検証関数・保存・番号採番・`history_append_review`・骨格）、`bin/subcon` の `source` 追加 | `schema/` `lib/review.sh` `lib/review-prompt.md` `lib/history.sh` `bin/subcon` | Haiku |
| 59 | ドライバの `SUBCON_ROLE=review`（agy の許可リスト、claude の dontAsk、opencode の拒否）と、`tests/fake-agy` `tests/fake-claude` の review 対応（改変の模擬を含む） | `drivers/agy` `drivers/claude` `drivers/opencode` `tests/` | 上位（実機確認を先に） |
| 60 | `subcon review <job-id>`（複製・一時コミット・事後検査・trap・成果物の回収・終了コード） | `lib/review.sh` `bin/subcon` | 上位 |
| 61 | `--target` `--brief` と `subcon reviews`（`bin/subcon` の振り分けと usage を含む） | `lib/review.sh` `bin/subcon` | Haiku |
| 62 | `commit` の `Reviewed-By` 自動付記と S1 の注意 | `lib/manage.sh` | Haiku |
| 63 | 文書追従（`docs/spec/cli.md` `files.md` `runner.md` `backend.md`、README、`docs/delegation.md` の監督の分担） | `docs/` `README.md` | Haiku |

59・60 は読み取り専用の担保という設計判断を含むので委任しない（`docs/delegation.md` の既定どおり）。
上位がテスト（fake の拡張と受け入れ条件）を先に書いてコミットしてから実装する。

## 決まっていないこと

- claude ドライバのタイムアウトは `timeout` / `gtimeout` が無い環境（素の macOS）では効かない（実装役でも同じ）。
  review では止まらないレビューが残りうる。coreutils を要求するか、シェルで見張るかは未決。

- 未コミットの作業ツリーを `--target` で読ませる方法（v1 は `HEAD` のみ）。
- container / ci ランナーで `review` 自体を動かすこと（v1 は常にローカル）。
- 別系統（Codex など）のレビュー役を同じジョブに複数かけること。`review-<n>` の番号で並べられるので
  構造としては足せる。
- `stats` の `by_role`、レビューの月次予算への算入。
