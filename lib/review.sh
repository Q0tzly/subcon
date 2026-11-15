# Review result checks, counts and numbering. Sourced by bin/subcon; defines functions only.
# Schema: schema/review.schema.json. Keep this in step with that file.

# review_validate <file>: exit 0 if <file> is a well-formed, consistent review; else 1 with one line on stderr.
review_validate() {
  local file="${1:?review file required}"

  if [[ ! -f "$file" ]] || ! jq -e . "$file" >/dev/null 2>&1; then
    echo "review: not a readable JSON file: $file" >&2
    return 1
  fi

  # Exact key sets: `keys` is sorted, so the lists below are sorted too.
  if ! jq -e '
    def finding_ok:
      type == "object"
      and (keys == ["failure_scenario","file","fix","line","severity","summary"])
      and (.severity | type == "string" and IN("S1","S2","S3"))
      and (.file | type == "string")
      and (.line | type == "number" and . == floor and . >= 0)
      and (.summary | type == "string")
      and (.failure_scenario | type == "string")
      and (.fix | type == "string");
    type == "object"
    and (keys == ["findings","summary","unverified","verdict"])
    and (.verdict | type == "string" and IN("approve","changes","reject"))
    and (.summary | type == "string")
    and (.findings | type == "array" and all(.[]; finding_ok))
    and (.unverified | type == "array" and all(.[]; type == "string"))
  ' "$file" >/dev/null 2>&1; then
    echo "review: result does not match schema/review.schema.json: $file" >&2
    return 1
  fi

  if jq -e '
    ((.findings | length) == 0 and .verdict != "approve")
    or (any(.findings[]; .severity == "S1") and .verdict == "approve")
  ' "$file" >/dev/null 2>&1; then
    jq -r '"review: inconsistent verdict: \(.verdict) with \(.findings | length) finding(s), \([.findings[] | select(.severity == "S1")] | length) of them S1"' "$file" >&2
    return 1
  fi

  return 0
}

# review_counts <file>: {"s1":n,"s2":n,"s3":n} on stdout. Assumes a validated review.
review_counts() {
  jq -c '{
    s1: ([.findings[] | select(.severity == "S1")] | length),
    s2: ([.findings[] | select(.severity == "S2")] | length),
    s3: ([.findings[] | select(.severity == "S3")] | length)
  }' "${1:?review file required}"
}

# review_next_n <dir>: the number for the next review in <dir>, judged by review-<n>.meta.json files.
review_next_n() {
  local dir="${1:?directory required}"
  local max=0 f base n
  for f in "$dir"/review-*.meta.json; do
    [[ -e "$f" ]] || continue
    base="${f##*/review-}"
    base="${base%.meta.json}"
    [[ "$base" =~ ^[0-9]+$ ]] || continue
    n=$((10#$base))
    if ((n > max)); then
      max=$n
    fi
  done
  echo $((max + 1))
}

# review_latest <dir>: path of review-<n>.json with the largest numeric n; exit 1 if there is none.
review_latest() {
  local dir="${1:?directory required}"
  local best="" bestn=-1 f base n
  for f in "$dir"/review-*.json; do
    base="${f##*/}"
    [[ "$base" =~ ^review-([0-9]+)\.json$ ]] || continue
    n=$((10#${BASH_REMATCH[1]}))
    if ((n > bestn)); then
      bestn=$n
      best=$f
    fi
  done
  [[ -n "$best" ]] || return 1
  echo "$best"
}
