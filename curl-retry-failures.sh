#!/usr/bin/env bash
# Retry lychee failures with curl when the failure looks like a checker problem
# rather than a dead link.
#
# Usage: curl-retry-failures.sh <lychee.json> [patterns-file]
#
# Reads the lychee JSON output, picks the error URLs worth re-checking, retries
# them with curl, and removes any that succeed from the JSON so they don't appear
# as errors in the report.
#
# A URL is retried when EITHER:
#   1. Its failure status is transient-looking (timeout, dropped/reset
#      connection, DNS hiccup, 429 rate limit, or lychee's bare "Error (cached)"
#      placeholder). This is domain-agnostic: any host can be slow under CI load,
#      and a genuinely dead link still fails `curl -sSf`, so this cannot hide a
#      real 404. Status-class matching is the primary trigger — the domain
#      allowlist below only ever added hosts after they had already produced a
#      false-positive issue (see kgateway-dev/kgateway.dev#947).
#   2. Its URL matches a pattern in the patterns file. This still earns its keep
#      for hosts that answer lychee with a *stable* bot-block or odd status code
#      (403/406 and friends) that status-class matching would not catch.
#
# The patterns file contains one grep -E pattern per line (blank lines and
# # comments are ignored). If omitted, uses curl-retry-patterns.txt next to
# this script. A missing or empty patterns file is fine — status-class retries
# still run.
#
# At most RETRY_MAX URLs (default 25) are retried, so a real upstream outage
# producing hundreds of timeouts can't stall the report step. Anything skipped by
# the cap is logged by URL and stays in the report as an error.
#
# Run resolve-cached-status.sh first: it turns "Error (cached)" into the real
# underlying status, which makes the classification below accurate instead of
# lumping every cached repeat into one bucket.
#
# The JSON file is modified in place.
set -euo pipefail

JSON_FILE="${1:?Usage: curl-retry-failures.sh <lychee.json> [patterns-file]}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERNS_FILE="${2:-$SCRIPT_DIR/curl-retry-patterns.txt}"
RETRY_MAX="${RETRY_MAX:-25}"

if [ ! -f "$JSON_FILE" ]; then
  echo "JSON file not found: $JSON_FILE" >&2
  exit 1
fi

# Failure statuses that mean "the check failed", not "the link is dead".
# Matched case-insensitively against lychee's status details.
#
# The cached placeholder is matched anchored, so it only fires when
# resolve-cached-status.sh could NOT find the underlying status. An unanchored
# "cached" would also match a resolved "Network error: Not Found (cached repeat)"
# and burn retry slots re-checking links that are genuinely dead.
#
# Literal parentheses are written as [(] / [)]: this pattern is passed to awk with
# -v, which strips unknown backslash escapes, so `\(` would silently degrade into
# a capture group and stop matching.
TRANSIENT_PATTERN='timed out|timeout|connection (closed|reset|refused|error)|error sending request|error trying to connect|channel closed|body stream|dns error|temporary failure in name resolution|too many requests|429|^error [(]cached[)]$|^cached$'

# Build a single grep -E pattern from the patterns file (skip blanks and comments)
COMBINED_PATTERN=""
if [ -f "$PATTERNS_FILE" ]; then
  COMBINED_PATTERN=$(grep -vE '^\s*(#|$)' "$PATTERNS_FILE" | paste -sd'|' - || true)
else
  echo "No curl-retry patterns file at $PATTERNS_FILE — using status-class retries only." >&2
fi

# Extract "url<TAB>details" for every error entry, excluding fragment/anchor
# warnings. Lychee puts both real errors and broken-anchor warnings in the same
# error_map. Fragment warnings contain "fragment" in their status details — skip
# those since curl can't verify anchors anyway (verify-anchors.sh handles them).
ERROR_ENTRIES=$(jq -r '
  (.error_map // .fail_map // {} | to_entries[] |
    .value as $v |
    if ($v | type) == "string" then "\($v)\t"
    elif ($v | type) == "object" then
      if (($v.status.details // $v.status.text // $v.details // "") | ascii_downcase | contains("fragment")) then empty
      else "\($v.url // $v.uri // "")\t\($v.status.details // $v.status.text // $v.details // "")"
      end
    elif ($v | type) == "array" then
      ($v[] |
        if ((.status.details // .status.text // .details // "") | ascii_downcase | contains("fragment")) then empty
        else "\(.url // .uri // "")\t\(.status.details // .status.text // .details // "")"
        end
      )
    else empty
    end
  ) | select(split("\t")[0] | length > 0)
' "$JSON_FILE" 2>/dev/null | sort -u || true)

if [ -z "$ERROR_ENTRIES" ]; then
  echo "No error URLs found in JSON — nothing to retry."
  exit 0
fi

# Select URLs to retry: transient status class, or a domain-allowlist match.
CANDIDATES=$(printf '%s\n' "$ERROR_ENTRIES" | awk -F'\t' \
  -v transient="$TRANSIENT_PATTERN" -v domains="$COMBINED_PATTERN" '
  {
    url = $1; details = tolower($2)
    if (details ~ transient) { print url; next }
    if (domains != "" && url ~ domains) { print url }
  }' | sort -u || true)

if [ -z "$CANDIDATES" ]; then
  echo "No error URLs look retryable (no transient statuses, no pattern matches) — nothing to retry."
  exit 0
fi

CANDIDATE_COUNT=$(printf '%s\n' "$CANDIDATES" | grep -c . || true)
RETRY_URLS=$(printf '%s\n' "$CANDIDATES" | head -n "$RETRY_MAX")
if [ "$CANDIDATE_COUNT" -gt "$RETRY_MAX" ]; then
  echo "WARNING: $CANDIDATE_COUNT retryable URL(s) exceeds RETRY_MAX=$RETRY_MAX. Not retried (still reported as errors):"
  printf '%s\n' "$CANDIDATES" | tail -n +"$((RETRY_MAX + 1))" | sed 's/^/  SKIPPED: /'
fi

RETRY_COUNT=$(printf '%s\n' "$RETRY_URLS" | grep -c . || true)
echo "Retrying $RETRY_COUNT URL(s) with curl..."

# Retry each URL with curl and collect the ones that succeed
PASSED_URLS=()
while IFS= read -r url; do
  [ -z "$url" ] && continue
  # Strip fragment — curl doesn't check anchors
  url_no_frag="${url%%#*}"
  if curl -sSf -o /dev/null -L --max-time 30 --retry 2 --retry-delay 3 \
       -A "Mozilla/5.0 (compatible; solo-link-checker/1.0)" \
       "$url_no_frag" 2>/dev/null; then
    echo "  PASS: $url"
    PASSED_URLS+=("$url")
  else
    echo "  FAIL: $url"
  fi
  # Be polite between requests
  sleep 1
done <<< "$RETRY_URLS"

if [ ${#PASSED_URLS[@]} -eq 0 ]; then
  echo "All retried URLs still failed — JSON unchanged."
  exit 0
fi

echo "Removing ${#PASSED_URLS[@]} false positive(s) from JSON..."

# Build a jq filter to remove passed URLs from the error_map
# Each error_map value can be a string, object, or array — handle all cases
JQ_FILTER='.'
for url in "${PASSED_URLS[@]}"; do
  # Escape the URL for use in a jq string comparison
  escaped=$(printf '%s' "$url" | sed 's/\\/\\\\/g; s/"/\\"/g')
  JQ_FILTER="$JQ_FILTER |
    if .error_map then
      .error_map |= with_entries(
        .value |= (
          if type == \"array\" then
            map(select((.url // .uri // \"\") != \"$escaped\"))
          elif type == \"object\" then
            if (.url // .uri // \"\") == \"$escaped\" then null else . end
          elif type == \"string\" then
            if . == \"$escaped\" then null else . end
          else .
          end
        ) | select(. != null) | select(if type == \"array\" then length > 0 else true end)
      )
    else . end |
    if .fail_map then
      .fail_map |= with_entries(
        .value |= (
          if type == \"array\" then
            map(select((.url // .uri // \"\") != \"$escaped\"))
          elif type == \"object\" then
            if (.url // .uri // \"\") == \"$escaped\" then null else . end
          elif type == \"string\" then
            if . == \"$escaped\" then null else . end
          else .
          end
        ) | select(. != null) | select(if type == \"array\" then length > 0 else true end)
      )
    else . end |
    if .timeout_map then
      .timeout_map |= with_entries(
        .value |= (
          if type == \"array\" then
            map(select((.url // .uri // \"\") != \"$escaped\"))
          elif type == \"object\" then
            if (.url // .uri // \"\") == \"$escaped\" then null else . end
          elif type == \"string\" then
            if . == \"$escaped\" then null else . end
          else .
          end
        ) | select(. != null) | select(if type == \"array\" then length > 0 else true end)
      )
    else . end"
done

# A timeout is recorded in .timeout_map while its cached repeats land in
# .error_map, so a URL cleared by curl has to be pruned from both maps or the
# stale timeout stays behind (invisible today, since the report only reads
# error_map, but ready to resurface the moment that changes).
JQ_FILTER="$JQ_FILTER | if .timeouts then .timeouts = ([.timeout_map[]? | if type == \"array\" then length elif . == null then 0 else 1 end] | add // 0) else . end"

# Recompute the error count from the pruned error_map rather than subtracting the
# number of passed URLs. Lychee's top-level .errors counts every failed check
# (the same URL on N pages counts N times, plus cached repeats), so it can be far
# larger than the entries actually listed in .error_map. Subtracting a unique-URL
# count left .errors stale (e.g. 53) after the arrays were emptied, which made the
# report claim "N broken link(s) found" with nothing to list. Deriving .errors
# from what remains in error_map keeps the count and the list in sync.
JQ_FILTER="$JQ_FILTER | if .errors then .errors = ([.error_map[]? | if type == \"array\" then length elif . == null then 0 else 1 end] | add // 0) else . end"

# Apply the filter
TMP_FILE=$(mktemp)
jq "$JQ_FILTER" "$JSON_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$JSON_FILE"

echo "Done. Removed ${#PASSED_URLS[@]} false positive(s)."
