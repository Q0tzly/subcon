# subcon stats

## Goal
`history.jsonl` を集計して、委任がどれだけ使われ、どれだけ役に立ったかを出す。

## Files
- lib/stats.sh

## Interface
`lib/stats.sh` の `cmd_stats` を実装する（空実装が置いてある）。履歴の形式は `docs/design/v2/10-history.md`。

`subcon stats [--all] [--since <N>d|<N>h] [--text]`

- 対象: `type: "job"` の行。`--all` が無ければ `repo` が今のリポジトリのトップと一致するものだけ（`--all` なら git リポジトリ外でも動く）
- `--since`: `^[0-9]+[dh]$` のみ受け付ける（`7d` = 7 日、`2h` = 2 時間）。それ以外は終了コード 1。`created_at` がその期間内の job だけを数える。日時の比較は jq の `fromdateiso8601` で行う
- 同じ `id` の job 行が複数あれば最後の 1 行だけを使う
- 未知のオプションは終了コード 1
- 履歴ファイルが無ければ job 0 件として扱う

stdout（`--text` なし）は次の JSON を 1 つ:

```
{
  "scope": "repo" | "all",
  "repo": <今のリポジトリのトップ> | null（--all のとき）,
  "since": "7d" | null,
  "jobs": <件数>,
  "by_state": {"finished": n, "failed": n},
  "by_status": {"done": n, "partial": n, "blocked": n, "none": n},
  "success": <state が finished かつ status が done かつ checks_ok が true の件数>,
  "success_rate": success / jobs（小数第 3 位で四捨五入）| null（jobs が 0）,
  "applied": <対象 job のうち applied イベントが 1 つ以上ある job の数>,
  "apply_rate": applied / jobs（同上）| null,
  "duration_s": {"total": 合計, "median": 中央値} | null（duration_s が null でない job が無い）,
  "tokens": {"input": 合計, "output": 合計, "total": 合計}（tokens が null の job は除く。該当なしなら全部 0）,
  "by_model": {"<model>": {"jobs": n, "success": n, "applied": n, "tokens_total": n}}
}
```

- キーの順番は上のとおり（`by_state` `by_status` の中も）
- `by_status.none` は `status` が null の件数
- 中央値は、件数が偶数なら中央 2 つの平均
- jobs が 0 なら `by_model` は `{}`

`--text`: 人間向けの表。JSON は出さない。少なくとも `Jobs: <件数>` で始まる行と、モデルごとの行（モデル名を含む）を出す。体裁は `rtk gain` を参考に自由。

## Acceptance
- `tests/run.sh stats`
- `tests/run.sh`（既存のテストも全部通ること）

## Notes
- 集計は jq で 1 回にまとめてよい（`jq -s` で全行を読み込む）。
- `lib/stats.sh` 以外は編集しない（特に `tests/`、`lib/history.sh`）。
- macOS の `/bin/bash` 3.2 で動くこと（連想配列・`mapfile`・`${x,,}` は使わない。`set -u` 下で空配列を `"${a[@]}"` と展開しない）。
