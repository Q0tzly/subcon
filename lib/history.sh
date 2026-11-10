# Append-only usage history, kept after discard (ticket 10).

history_file() { echo "$(state_root)/history.jsonl"; }

# No-op stubs until ticket 10: callers run these from finalize and apply.
history_append_job() { :; }

history_append_event() { :; }
