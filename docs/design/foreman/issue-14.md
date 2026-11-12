# docs: runner.md をドライバ規約に沿った一般形に直す

## Goal
docs/spec/runner.md の責務節と local 節にある agy 固有の記述（stream-json 前提・会話 ID の回収手順）を、drivers/<name> のドライバ規約に沿った一般形に書き換える。あわせて container-entry の subcon-driver-agy 命名とドライバ規約の対応を文書化する

## Files
- docs/spec/runner.md

## Interface
文書のみの変更。仕様の意味は変えず、記述を実装（ドライバ層）に一致させる。実装の正は drivers/ 配下と docs/design/driver-layer.md

## Acceptance
- `bash tests/run.sh`

## Notes
agy 固有の事情（stream-json の init イベントから conversation_id を取る等）は、ドライバ側の責務として一般形で表現し直すこと。agy ドライバ固有の注記が必要なら、その旨を明示して残してよい
Source: Q0tzly/subcon#14, comment 6814389543, sha256 759ecab17f5ca2ab3fe890256e881504466516e73888a6a58d035b2a084d31dd
