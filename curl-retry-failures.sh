#!/usr/bin/env bash
# Retry lychee failures with curl for domains known to drop connections under load.
#
# Usage: curl-retry-failures.sh <lychee.json> [patterns-file]
#
# Reads the lychee JSON output, extracts error URLs that match patterns in the
# patterns file, retries them with curl, and removes any that succeed from the
# JSON so they don't appear as errors in the report.
#
# The patterns file contains one grep -E pattern per line (blank lines and
# # comments are ignored). If omitted, uses curl-retry-patterns.txt next to
# this script.
#
# The JSON file is modified in place.
set -euo pipefail

JSON_FILE="${1:?Usage: curl-retry-failures.sh <lychee.json> [patterns-file]}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERNS_FILE="${2:-$SCRIPT_DIR/curl-retry-patterns.txt}"

if [ ! -f "$JSON_FILE" ]; then
  echo "JSON file not found: $JSON_FILE" >&2
  exit 1
fi

if [ ! -f "$PATTERNS_FILE" ]; then
  echo "No curl-retry patterns file found at $PATTERNS_FILE — skipping retry step." >&2
  exit 0
fi

# Build a single grep -E pattern from the file (skip blanks and comments)
COMBINED_PATTERN=$(grep -vE '^\s*(#|$)' "$PATTERNS_FILE" | paste -sd'|' -)
if [ -z "$COMBINED_PATTERN" ]; then
  echo "Patterns file is empty — skipping retry step." >&2
  exit 0
fi

# Extract unique error URLs from lychee JSON
ERROR_URLS=$(jq -r '
  (.error_map // .fail_map // {} | to_entries[] |
    .value as $v |
    if ($v | type) == "string" then $v
    elif ($v | type) == "object" then ($v.url // $v.uri // empty)
    elif ($v | type) == "array" then ($v[] | .url // .uri // empty)
    else empty
    end
  )
' "$JSON_FILE" 2>/dev/null | sort -u || true)

if [ -z "$ERROR_URLS" ]; then
  echo "No error URLs found in JSON — nothing to retry."
  exit 0
fi

# Filter to only URLs matching the retry patterns
RETRY_URLS=$(echo "$ERROR_URLS" | grep -E "$COMBINED_PATTERN" || true)

if [ -z "$RETRY_URLS" ]; then
  echo "No error URLs match retry patterns — nothing to retry."
  exit 0
fi

RETRY_COUNT=$(echo "$RETRY_URLS" | wc -l | tr -d ' ')
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
    else . end"
done

# Also update the error count
JQ_FILTER="$JQ_FILTER | if .errors then .errors = (.errors - ${#PASSED_URLS[@]} | if . < 0 then 0 else . end) else . end"

# Apply the filter
TMP_FILE=$(mktemp)
jq "$JQ_FILTER" "$JSON_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$JSON_FILE"

echo "Done. Removed ${#PASSED_URLS[@]} false positive(s)."
