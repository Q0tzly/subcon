# 28: 入口コマンドの健全化（run / resume / trailer / wait）

## Goal

Argon の仕様レビューで見つかった入口まわりの不整合を直す: `run` が複数票を受けて孤児ジョブを作る、CI ランナーで `resume` が拒否されず別物として走る、`trailer` だけ引数解析の流儀が違う、`wait` のタイムアウト判定が遅れる。

## Files

- lib/query.sh
- lib/job.sh
- lib/common.sh

## Interface

- `subcon run`:
  - 票は 1 枚だけ受け付ける。オプション（--runner / --model / --timeout）を除いた位置引数が 2 つ以上、または 0 の場合は、ジョブを 1 つも作らず終了コード 1（stderr に理由）。検証はジョブ作成より前に行う
  - 票 1 枚のときの挙動（submit の失敗時の出力と終了コードを含む）は現状維持
- `subcon resume`:
  - 対象ジョブの runner が `ci` の場合は再開できない。meta.json から runner が分かった時点で、状態や会話の有無の検証より先に、終了コード 1 で拒否する。stderr の文面は `resume is not supported for the ci runner` を含むこと
  - それ以外の runner の挙動は現状維持
- `subcon trailer`:
  - 引数解析を他のコマンドと揃える。未知のオプションや余分な位置引数は `unknown option: <arg>` で die（終了コード 1）。`--model` の値が無い場合は `--model requires a value` で die する。bash の `${2:?...}` のような素のエラーは出さない
  - 正常系（引数なし、`--model <id>`）の出力は現状維持
- `subcon wait`:
  - タイムアウト判定を経過時間（SECONDS）だけで行う。現行の `sleep_count >= timeout * 2` の条件は外す（ループ 1 回の処理が重いとタイムアウトが遅れるため）

## Acceptance

```sh
./tests/run.sh entry
./tests/run.sh
```

## Notes

- 起点では entry グループ 5 件中 4 件が落ちる（trailer の正常系だけが番人として通る）
- wait のタイムアウト判定は決定的なテストが書きにくいため、受け入れテストは付けていない。既存の query グループが回帰の番人になる
