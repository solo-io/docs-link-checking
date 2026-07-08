#!/usr/bin/env bash
# Verify broken-anchor (fragment) warnings against the real page and prune the
# ones that actually resolve.
#
# Usage: verify-anchors.sh <lychee.json>
#
# Lychee's fragment checker only recognizes an anchor target when it finds a
# matching `id="..."` or `name="..."` in the *static* HTML. Some sites expose
# their in-page anchors differently:
#   - a `data-key="..."` (or similar) attribute that JS uses to scroll on #hash
#     (for example legal.solo.io, a Next.js SPA)
#   - an `id="..."` that is injected by JavaScript at runtime and so is absent
#     from the static HTML lychee parses
# For those pages lychee reports "Cannot find fragment" even though the anchor
# works in a browser. This script re-checks each fragment warning against the
# page as a browser would see it and removes the confirmed-good ones from the
# JSON, so the report is accurate instead of us blanket-ignoring the URL in
# lychee.toml (which would also hide genuinely broken anchors on that domain).
#
# How a page is fetched, in order of preference:
#   1. A headless Chromium/Chrome render (executes JS) if a browser is found —
#      set CHROME_BIN, or it probes common paths and `npx playwright`.
#   2. A plain curl --compressed fetch (catches data-key / non-id anchors that
#      are already in the static HTML, like legal.solo.io).
# A fragment counts as resolved if it appears as id=, name=, data-key=, or an
# <a name=> in the fetched DOM. Only then is the warning pruned; genuinely
# broken anchors (renamed/removed sections) stay in the report.
#
# The JSON file is modified in place. Only external http(s) anchors are checked;
# local file:// fragments are left for lychee to resolve against the built site.
set -euo pipefail

JSON_FILE="${1:?Usage: verify-anchors.sh <lychee.json>}"

if [ ! -f "$JSON_FILE" ]; then
  echo "JSON file not found: $JSON_FILE" >&2
  exit 1
fi

# --- Locate a headless browser (optional; curl fallback if none) ---
find_browser() {
  # Escape hatch for CI or testing the static-HTML (curl) path.
  [ -n "${ANCHOR_VERIFY_NO_BROWSER:-}" ] && return 1
  if [ -n "${CHROME_BIN:-}" ] && [ -x "$CHROME_BIN" ]; then
    printf '%s' "$CHROME_BIN"; return 0
  fi
  local candidates=(
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    "/Applications/Chromium.app/Contents/MacOS/Chromium"
    "google-chrome" "google-chrome-stable" "chromium" "chromium-browser"
  )
  local c
  for c in "${candidates[@]}"; do
    if [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
    if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return 0; fi
  done
  # Playwright's bundled chromium, if installed anywhere obvious
  local pw
  pw=$(ls "$HOME"/Library/Caches/ms-playwright/chromium-*/chrome-*/*/Google\ Chrome\ for\ Testing 2>/dev/null | head -1 || true)
  [ -z "$pw" ] && pw=$(ls "$HOME"/.cache/ms-playwright/chromium-*/chrome-linux/chrome 2>/dev/null | head -1 || true)
  if [ -n "$pw" ] && [ -x "$pw" ]; then printf '%s' "$pw"; return 0; fi
  return 1
}

BROWSER="$(find_browser || true)"
if [ -n "$BROWSER" ]; then
  echo "Using headless browser for anchor verification: $BROWSER"
else
  echo "No headless browser found — falling back to curl (static-HTML anchors only)."
fi

# Fetch the rendered (or static) DOM for a URL to stdout.
fetch_dom() {
  local url="$1"
  if [ -n "$BROWSER" ]; then
    "$BROWSER" --headless=new --disable-gpu --no-sandbox --no-first-run \
      --virtual-time-budget=8000 --timeout=20000 --dump-dom "$url" 2>/dev/null && return 0
  fi
  curl -sSL --compressed --max-time 30 --retry 2 --retry-delay 3 \
    -A "Mozilla/5.0 (compatible; solo-link-checker/1.0)" "$url" 2>/dev/null
}

# --- Extract fragment-warning URLs (external http/https only) ---
FRAG_URLS=$(jq -r '
  (.error_map // .fail_map // {} | to_entries[] |
    .value as $v |
    if ($v | type) == "object" then
      if (($v.status.details // $v.status.text // $v.details // "") | ascii_downcase | contains("fragment")) then ($v.url // $v.uri // empty) else empty end
    elif ($v | type) == "array" then
      ($v[] | if ((.status.details // .status.text // .details // "") | ascii_downcase | contains("fragment")) then (.url // .uri // empty) else empty end)
    else empty
    end
  )
' "$JSON_FILE" 2>/dev/null | grep -E '^https?://.+#.+' | sort -u || true)

if [ -z "$FRAG_URLS" ]; then
  echo "No external fragment warnings to verify — nothing to do."
  exit 0
fi

FRAG_COUNT=$(echo "$FRAG_URLS" | wc -l | tr -d ' ')
echo "Verifying $FRAG_COUNT fragment anchor(s)..."

# Cache DOM per base URL (many anchors can share a page)
CACHE_DIR=$(mktemp -d)
trap 'rm -rf "$CACHE_DIR"' EXIT

PASSED_URLS=()
while IFS= read -r url; do
  [ -z "$url" ] && continue
  base="${url%%#*}"
  frag="${url#*#}"
  # Percent-decode a couple of common cases so id="..." comparisons line up
  frag_decoded=$(printf '%s' "$frag" | sed 's/%20/ /g; s/%22/"/g; s/%29/)/g')

  cache_key=$(printf '%s' "$base" | tr -c '[:alnum:]' '_')
  dom_file="$CACHE_DIR/$cache_key.html"
  [ -f "$dom_file" ] || fetch_dom "$base" > "$dom_file" || true

  # An anchor resolves if the fragment appears as id/name/data-key (double or
  # single quoted). grep -F on the value keeps regex-special fragment chars safe.
  found=0
  for attr in 'id' 'name' 'data-key'; do
    if grep -qF "$attr=\"$frag_decoded\"" "$dom_file" 2>/dev/null \
       || grep -qF "$attr='$frag_decoded'" "$dom_file" 2>/dev/null; then
      found=1; break
    fi
  done

  if [ "$found" -eq 1 ]; then
    echo "  RESOLVED: $url"
    PASSED_URLS+=("$url")
  else
    echo "  STILL BROKEN: $url"
  fi
done <<< "$FRAG_URLS"

if [ ${#PASSED_URLS[@]} -eq 0 ]; then
  echo "No fragment warnings verified as resolvable — JSON unchanged."
  exit 0
fi

echo "Removing ${#PASSED_URLS[@]} verified anchor(s) from JSON..."

# Prune passed URLs from error_map/fail_map, then recompute .errors from what
# remains (same approach as curl-retry-failures.sh — lychee's top-level count
# double-counts the same URL across pages, so derive it from the pruned map).
JQ_FILTER='.'
for url in "${PASSED_URLS[@]}"; do
  escaped=$(printf '%s' "$url" | sed 's/\\/\\\\/g; s/"/\\"/g')
  JQ_FILTER="$JQ_FILTER |
    if .error_map then
      .error_map |= with_entries(
        .value |= (
          if type == \"array\" then map(select((.url // .uri // \"\") != \"$escaped\"))
          elif type == \"object\" then (if (.url // .uri // \"\") == \"$escaped\" then null else . end)
          elif type == \"string\" then (if . == \"$escaped\" then null else . end)
          else . end
        ) | select(. != null) | select(if type == \"array\" then length > 0 else true end)
      )
    else . end |
    if .fail_map then
      .fail_map |= with_entries(
        .value |= (
          if type == \"array\" then map(select((.url // .uri // \"\") != \"$escaped\"))
          elif type == \"object\" then (if (.url // .uri // \"\") == \"$escaped\" then null else . end)
          elif type == \"string\" then (if . == \"$escaped\" then null else . end)
          else . end
        ) | select(. != null) | select(if type == \"array\" then length > 0 else true end)
      )
    else . end"
done
JQ_FILTER="$JQ_FILTER | if .errors then .errors = ([.error_map[]? | if type == \"array\" then length elif . == null then 0 else 1 end] | add // 0) else . end"

TMP_FILE=$(mktemp)
jq "$JQ_FILTER" "$JSON_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$JSON_FILE"

echo "Done. Removed ${#PASSED_URLS[@]} verified anchor(s)."
