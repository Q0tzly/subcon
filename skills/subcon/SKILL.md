---
name: subcon
description: Delegate a well-specified implementation ticket to Gemini Flash with the subcon CLI, then review and apply the resulting patch. Use when a task spans several files, the touched files, interfaces and acceptance commands can be written down up front, and throwing the diff away is cheap.
---

# subcon

`subcon` hands a work ticket to Gemini Flash (via agy) as a background job, and returns the result as a patch you review before applying.

Before delegating anything, run `subcon guide` and follow it. It holds the rules: when to delegate at all (default is to implement it yourself), the ticket format, the review checklist and the commit trailers.

Typical flow:

```sh
subcon new <feature>/<NN-name>        # scaffold a ticket, fill it in, commit it
subcon submit <ticket>...             # start jobs; stdout is JSON with the job ids
subcon wait --timeout 540 <id>...     # exit code 5 means still running: call it again
subcon diff <id>                      # read the whole patch
subcon apply <id>                     # apply to the working tree; does not commit
subcon discard <id>
```

- Only committed tickets can be submitted: jobs start from `HEAD`.
- stdout is JSON (except `diff`, `guide`, `trailer`); progress and errors go to stderr.
- A job with `state: failed` and a non-null `conversation` can be continued with `subcon resume <id>`.
- Run the ticket's acceptance commands yourself after `apply`; never trust the job's own report alone.
- Use `subcon trailer` for the implementer's `Co-Authored-By` line.
