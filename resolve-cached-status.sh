#!/usr/bin/env bash
# Replace lychee's placeholder "Error (cached)" status with the real underlying status.
#
# Usage: resolve-cached-status.sh <lychee.json>
#
# Lychee memoizes each URL within a run. The first occurrence records the real
# status; every later occurrence of the same URL reports the generic placeholder
# `Error (cached)`. Two problems follow from that:
#
#   1. The report shows `Error (cached)`, which says nothing about whether the
#      link is dead (404) or the check merely failed (timeout, rate limit), so
#      the issue can't be triaged without digging out the raw lychee log.
#   2. A timeout is recorded in `.timeout_map`, which the report never reads,
#      while its cached repeats land in `.error_map`, which the report does read.
#      So a transient timeout surfaces only in its least informative form.
#      See kgateway-dev/kgateway.dev#947 for an example of both.
#
# This script looks up each cached failure's URL in the other status maps
# (`timeout_map`, plus non-cached entries in `error_map` / `fail_map`) and
# rewrites the placeholder to "<real status> (cached repeat)". Cached failures
# whose underlying status isn't in the JSON are left untouched and counted.
#
# Run this BEFORE curl-retry-failures.sh (so the retry step can classify the
# failure) and BEFORE verify-anchors.sh (a cached repeat of a fragment failure
# becomes a fragment warning here, which is what verify-anchors.sh re-checks).
#
# The JSON file is modified in place.
set -euo pipefail

JSON_FILE="${1:?Usage: resolve-cached-status.sh <lychee.json>}"

if [ ! -f "$JSON_FILE" ]; then
  echo "JSON file not found: $JSON_FILE" >&2
  exit 1
fi

# Shared jq helpers: flatten a status map into its individual failure entries,
# read whichever details field lychee used, and detect the cached placeholder.
JQ_LIB='
def failures($m):
  ($m // {}) | to_entries[] | .value as $v |
  ( if ($v | type) == "array" then $v[]
    elif ($v | type) == "object" then $v
    else empty
    end );
def details: (.status.details // .status.text // .details // "");
def is_cached: (details | ascii_downcase | test("cached"));
def entry_url: (.url // .uri // "");
'

# Report what is about to change (and what cannot be resolved) before touching
# the JSON, so a CI log shows the mapping rather than a silent rewrite.
jq -r "$JQ_LIB"'
  [ failures(.timeout_map), failures(.error_map), failures(.fail_map)
    | select(is_cached | not)
    | select(entry_url != "" and details != "")
    | {key: entry_url, value: details} ] as $pairs
| (reduce $pairs[] as $p ({}; if .[$p.key] then . else .[$p.key] = $p.value end)) as $known
| [ failures(.error_map), failures(.fail_map)
    | select(is_cached)
    | select(entry_url != "")
    | entry_url ] | unique
| map(if $known[.] then "  RESOLVED: \(.) -> \($known[.])" else "  UNRESOLVED: \(.)" end)
| .[]
' "$JSON_FILE" 2>/dev/null || true

TMP_FILE=$(mktemp)
jq "$JQ_LIB"'
  [ failures(.timeout_map), failures(.error_map), failures(.fail_map)
    | select(is_cached | not)
    | select(entry_url != "" and details != "")
    | {key: entry_url, value: details} ] as $pairs
| (reduce $pairs[] as $p ({}; if .[$p.key] then . else .[$p.key] = $p.value end)) as $known
| def relabel($new):
    if has("status") then (.status.details = $new | .status.text = $new)
    else .details = $new
    end;
  def fix_entry:
    if (type == "object") and is_cached and (($known[entry_url] // "") != "")
    then relabel("\($known[entry_url]) (cached repeat)")
    else .
    end;
  def fix_map:
    with_entries(.value |= (
      if type == "array" then map(fix_entry)
      elif type == "object" then fix_entry
      else .
      end
    ));
  (if has("error_map") then .error_map |= fix_map else . end)
| (if has("fail_map") then .fail_map |= fix_map else . end)
' "$JSON_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$JSON_FILE"

echo "Cached status labels resolved where the underlying status was available."
