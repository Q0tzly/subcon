# docs: README に foreman 連携の概要節を追加する

## Goal
README に foreman による issue 駆動フロー（auto → 下書き → approved → intake 検証 → mini で subcon 実行 → Draft PR）の概要節を追加する

## Files
- README.md

## Interface
変更は README.md のみ。他のファイルは変更しない。見出しは「## foreman 連携」

## Acceptance
- `grep -qi foreman README.md`

## Notes
foreman v0 の e2e ドッグフーディング用。簡潔に書き、詳細は Q0tzly/foreman の docs/DESIGN.md へのリンクで済ませる
Source: Q0tzly/subcon#12, comment 6813128177, sha256 86acea84afe4b5dc7a218cc91d6393bda4062ca88ebbf7ca79cfb49fdaa537fe
