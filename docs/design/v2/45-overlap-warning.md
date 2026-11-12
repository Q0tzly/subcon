# 45-overlap-warning

## Goal

`subcon submit`（と、それを経由する `subcon run`）が新しいジョブを作るとき、**実行中（queued / running）の他ジョブと `## Files` が重なっていたら stderr に警告を出す**。ブロックはしない。

背景: 並行投入したジョブ同士が同じファイルを触ると、後から apply する側のパッチが競合する。現行は重なりに気づく手段が無く、検収時に初めて分かる。投入時点で見えれば、監督側が直列化や票の切り直しを判断できる。

## Files

- lib/job.sh
- docs/spec/cli.md

## 仕様

- 場所: `cmd_submit` の Step 3 ループで、各ジョブの `job_create` 成功直後にそのジョブについて検査する。これにより (a) 既存の実行中ジョブとの重なり、(b) 同一 submit 呼び出しで先に作られたジョブとの重なり、の両方が拾える。`cmd_run` は `cmd_submit` 経由なので自動で対象になる。
- 検査内容: 新ジョブの票の `## Files`（`ticket_files` で取得）と、状態ディレクトリにある **state が queued または running の他ジョブ** の `ticket.md` の `## Files` を比べ、共通するパスがあれば警告する。自分自身は除外する。finished / failed のジョブは対象外。
- 警告の形（stderr、重なるジョブごとに1行）:
  `subcon: warning: <票パス> overlaps with active job <ジョブID> on: <パス1, パス2>`
- 警告は submit の成否・終了コードに影響しない。
- `docs/spec/cli.md`: submit の説明に警告の存在を1行足す。

## Acceptance

- 受け入れテスト（tests/run.sh、監督が先行コミット済み）:
  - `test_submit_overlap_warn_active`: sleep 中のジョブと重なる票を submit すると、stderr に相手ジョブの ID と重なったパスを含む警告が出て、submit 自体は成功する。
  - `test_submit_overlap_no_warn_disjoint`: 重ならない票では警告が出ない。
  - `test_submit_overlap_no_warn_finished`: 相手ジョブが終了した後なら、重なる票でも警告が出ない。
- 全テスト合格。
