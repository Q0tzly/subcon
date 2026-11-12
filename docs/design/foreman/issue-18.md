# docs: README の foreman 連携節に automerge の説明を追記する

## Goal
README の foreman 連携の節に、下書き票が automerge（docs / tested）を宣言した場合はチェック全緑で PR が自動マージされる旨を簡潔に追記する

## Files
- README.md

## Interface
変更は README.md のみ。既存の foreman 連携節の流れに沿った1〜3文の追記に留める

## Acceptance
- `grep -qi automerge README.md`

## Notes
foreman 票10 の e2e。自動マージが成立すれば issue は Closes で閉じ、in-pr ラベルも cleanup で剥がれる想定
Source: Q0tzly/subcon#18, comment 6815919843, sha256 91faa2bbb40592dc5eb54416be32c9eb6a1e3e0ce3801918db45d9da342338fe
