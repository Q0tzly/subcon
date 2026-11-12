# fix: trailer の直近ジョブ判定を created_at 順にする

## Goal
latest_job_meta の「直近」判定がジョブ ID の辞書順（秒精度）で、同一秒に作られたジョブ同士の前後が不定な問題を、meta.json の created_at を主キーとする判定に直す

## Files
- lib/common.sh
- tests/run.sh

## Interface
latest_job_meta の返却仕様（直近ジョブの meta.json のパス）は不変。並び順の決定方法のみ変更する。created_at が同値の場合は meta.json の mtime、それも同値ならジョブ ID の辞書順をタイブレークとする。ジョブ ID の形式は変更しない。macOS / Linux の stat 書式差異に依存しない方法を優先する

## Acceptance
- `bash tests/run.sh`

## Notes
issue 本文の「直すなら」節が方向性。同一秒に作られた複数ジョブでも created_at が最新のものが選ばれることを検証するテストを追加すること
Source: Q0tzly/subcon#5, comment 6814386029, sha256 eb66a649ed0efe80b8144a4db496ef5ed5115758f4666e80678f9588e7b6220c
