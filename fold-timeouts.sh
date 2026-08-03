#!/usr/bin/env bash
# Fold lychee's timeout_map entries into error_map so timeouts get reported.
#
# Usage: fold-timeouts.sh <lychee.json>
#
# Lychee records a timed-out check in `.timeout_map`, separate from `.error_map`.
# The report only reads error_map, so before this step a timeout reached the
# report solely through its *cached repeats* (a URL used on 2+ pages), and a URL
# used on exactly one page timed out silently. That is backwards: the single-page
# case is no less broken, and the multi-page case only ever surfaced as an
# untriageable "Error (cached)". See kgateway-dev/kgateway.dev#947.
#
# Each timeout entry is copied into error_map under the same source page, keyed by
# (source, url) so re-running this is a no-op and a URL that already has an error
# entry for that page isn't listed twice. Entries stay in timeout_map as well, so
# `.timeouts` still describes the run; curl-retry-failures.sh prunes both maps.
#
# Run this BEFORE curl-retry-failures.sh. That ordering is the whole point: a
# timeout is the most transient failure class there is, so it gets a curl
# re-check first and only persistent timeouts reach the report.
#
# The JSON file is modified in place.
set -euo pipefail

JSON_FILE="${1:?Usage: fold-timeouts.sh <lychee.json>}"

if [ ! -f "$JSON_FILE" ]; then
  echo "JSON file not found: $JSON_FILE" >&2
  exit 1
fi

JQ_PROGRAM='
def items: if type == "array" then . elif type == "object" then [.] else [] end;
def entry_url: (.url // .uri // "");

reduce ((.timeout_map // {}) | to_entries[] as $src
        | $src.value | items | .[] | {source: $src.key, item: .}) as $t
  (.;
    ((.error_map // {})[$t.source] // []) as $cur
    | if ($cur | type) != "array" then .
      elif ([$cur[] | entry_url] | index($t.item | entry_url)) then .
      else .error_map[$t.source] = ($cur + [$t.item])
      end
  )
| .errors = ([.error_map[]? | if type == "array" then length elif . == null then 0 else 1 end] | add // 0)
'

BEFORE=$(jq -r '[.error_map[]? | if type == "array" then length elif . == null then 0 else 1 end] | add // 0' "$JSON_FILE" 2>/dev/null || echo 0)

TMP_FILE=$(mktemp)
jq "$JQ_PROGRAM" "$JSON_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$JSON_FILE"

AFTER=$(jq -r '.errors // 0' "$JSON_FILE" 2>/dev/null || echo 0)
FOLDED=$((AFTER - BEFORE))

if [ "$FOLDED" -gt 0 ]; then
  echo "Folded $FOLDED timeout entr(ies) into error_map (subject to the curl retry below):"
  jq -r '[(.timeout_map // {}) | to_entries[] | .value[]? | (.url // .uri // "")] | unique | .[] | "  TIMEOUT: \(.)"' \
    "$JSON_FILE" 2>/dev/null || true
else
  echo "No timeout entries to fold."
fi
