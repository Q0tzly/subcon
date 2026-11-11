# `subcon commit`（trailer の自動付与）

## Goal
検収を通ったジョブの変更を、trailer（`Co-Authored-By:` 実装者／`Reviewed-By:` レビュアー）を自動で付けてコミットするコマンドを足す。今は実装者行だけ `subcon trailer` が出し、レビュアー行は上位が毎回手で書いている。レビュアー名義は環境変数 `SUBCON_REVIEWER` に最初に 1 回設定すればよい形にし、毎回の手書きをメッセージ本文だけにする。

## Files
- bin/subcon
- lib/manage.sh
- docs/design/v2.md
- docs/delegation.md

## Interface
`lib/manage.sh` に `cmd_commit` を足し、`bin/subcon` に振り分けと usage を足す（票09で stats の振り分けを足した前例に従う）。

使い方: `subcon commit -m <message> [--edited] <id>`（オプションは id の前。`-m` は必須）

動作:

1. id のジョブが無ければ終了コード 1（`cmd_apply` と同じ文言・手順でよい）。ジョブの `repo` が今のリポジトリのトップと一致しなければ終了コード 1（`cmd_apply` と同じ）
2. `SUBCON_REVIEWER` が未設定・空なら、何も変えず `die "SUBCON_REVIEWER is not set (e.g. SUBCON_REVIEWER='Name <email>')"` で終了コード 1
3. `-m` が無ければ使い方の誤りとして終了コード 1
4. ジョブの結果（`job_result`）が `state: finished` でなければ終了コード 1。`checks` が無く、`checks.ok` が true でなく、`checks.files_changed` が空なら、それぞれ理由を stderr に出して終了コード 1（チェック違反や変更ゼロのジョブはこの経路でコミットさせない）
5. `checks.files_changed` のパスだけを `git -C <repo> add -A -- <パス...>` でステージする（票の範囲外の変更や未追跡ファイルを巻き込まない）。ステージ結果が空なら（未 apply・コミット済み等）理由を出して終了コード 1
6. コミットする。メッセージは「`<message>`、空行、trailer ブロック」の形で、trailer は 1 つの段落に連続させる（間に空行を入れない）:
   - `Co-Authored-By: <実装者名> <SUBCON_COAUTHOR_EMAIL>`。実装者名は**ジョブの** `meta.json` の `model` から、既存の `model_name`（`lib/common.sh`）で引く。引けなければ終了コード 1
   - `--edited` のときだけ `Co-Authored-By: $SUBCON_REVIEWER` をもう 1 行足す（検収後に上位が手を入れた場合の既存規約）
   - `Reviewed-By: $SUBCON_REVIEWER`
7. 成功したら `history_append_event "$id" committed` を記録し（失敗しても警告に留める。`cmd_apply` の `applied` と同じ扱い）、stdout に `{"id": ..., "commit": "<新しい HEAD のフルハッシュ>"}` を出す

ドキュメント:

- `docs/design/v2.md`: コマンド表に `commit` の行を足し、使い方の例（「上位エージェント向けの使い方」）の `git commit` を `subcon commit` に置き換える
- `docs/delegation.md`: 「コミット」節を新しい手順に書き換える（`SUBCON_REVIEWER` を最初に設定すること、`subcon commit -m ... [--edited] <id>` で trailer が自動で付くこと、手でコミットする場合の trailer 形式は従来通り残す）

合格テストは上位が先に書いてコミット済み（`tests/run.sh` に commit グループを追加した）。開始時点では 10 件中 6 件（本体の振る舞いを見るもの）が落ちるのが正しい状態。残り 4 件は「終了コード 1 で拒否されること」だけを見るため、未実装（usage エラー）でも通る。

## Acceptance
- `tests/run.sh commit`
- `tests/run.sh`（既存のテストも全部通ること）

## Notes
- `bin/subcon`、`lib/manage.sh`、`docs/design/v2.md`、`docs/delegation.md` 以外は編集しない（特に `tests/`、`lib/common.sh`、`lib/job.sh`）。
- macOS の `/bin/bash` 3.2 で動くこと（連想配列・`mapfile`・`${x,,}` は使わない。`set -u` 下で空配列を `"${a[@]}"` と展開しない）。`files_changed` は手順 4 で空でないことを確かめてから使う。
- コミットは今のリポジトリに対して `git -C` で行う（サブディレクトリからでも動くこと。`cmd_apply` の前例）。
- trailer のメールアドレスは既存の決め打ち（`SUBCON_COAUTHOR_EMAIL`、既定 `noreply@google.com`）をそのまま使う。
- `subcon trailer` 自体は変更しない。
