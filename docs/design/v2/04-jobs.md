# ジョブ本体: submit / wait / run / show

## Goal
票をジョブとして worktree で非同期に実行し、パッチと結果 JSON を返す。設計は `docs/design/v2.md` の「ジョブ」「ランナー契約」節がすべて。

## Files
- lib/job.sh
- runners/local
- bin/subcon

## Interface
`docs/design/v2.md` の次の部分をそのとおりに実装する。
- コマンド表の `submit` `wait` `run` `show` の行
- 終了コードの表
- 「ジョブ」節（保存場所・ID・`result.json` の形・流れ）
- 「ランナー契約」節と local ランナー

## Acceptance
- `tests/run.sh jobs`

## Notes
- agy の呼び出しとプロンプト・権限設定は v1（`bin/subcon` の旧 `main`、`lib/prompt.md`）と同じものを使う。
- `submit` が返った時点で、ランナーは呼び出し元のシェルと切り離されていること（`nohup` と `&`）。
- `wait` はポーリングでよい（0.5 秒間隔）。
- 上位の作業ツリーは一切変更しない。変更は `work/` の中だけ。
- `tests/` と `lib/common.sh` は編集しない。
