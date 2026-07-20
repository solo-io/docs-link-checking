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
# The JSON file is modified in place. External http(s) anchors are always
# checked. Local file:// fragments (against the built site) are checked whenever
# a PUBLIC_DIR is passed as $2. This is safe to always run: lychee already
# resolves id=/name= fragments for local files, so anything reaching this pass
# has already failed that check — the only anchors this can prune are ones that
# resolve via data-key/data-ks-path in the static HTML (the JS-widget case, for
# example the kubespec tree, which drives in-page navigation from data-ks-path
# plus a hashchange handler rather than a real id=). Repos with no such widgets
# see nothing pruned. Local pages are checked against static HTML only (no
# browser), so the added cost is a grep per local fragment warning.
set -euo pipefail

JSON_FILE="${1:?Usage: verify-anchors.sh <lychee.json> [public_dir]}"
PUBLIC_DIR="${2:-}"

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

# A fragment resolves if it appears as id/name/data-key/data-ks-path (double or
# single quoted). data-key covers SPA scroll targets (legal.solo.io); data-ks-path
# covers the kubespec tree widget. grep -F keeps regex-special fragment chars safe.
frag_in_dom() {
  local file="$1" frag="$2" attr
  for attr in 'id' 'name' 'data-key' 'data-ks-path'; do
    if grep -qF "$attr=\"$frag\"" "$file" 2>/dev/null \
       || grep -qF "$attr='$frag'" "$file" 2>/dev/null; then
      return 0
    fi
  done
  return 1
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
' "$JSON_FILE" 2>/dev/null | sort -u || true)

# External anchors are always verified; local file:// anchors whenever a valid
# PUBLIC_DIR is available to resolve them against the built site.
EXT_FRAG_URLS=$(printf '%s\n' "$FRAG_URLS" | grep -E '^https?://.+#.+' || true)
LOCAL_FRAG_URLS=""
if [ -n "$PUBLIC_DIR" ] && [ -d "$PUBLIC_DIR" ]; then
  LOCAL_FRAG_URLS=$(printf '%s\n' "$FRAG_URLS" | grep -E '^file://.+#.+' || true)
fi

if [ -z "$EXT_FRAG_URLS" ] && [ -z "$LOCAL_FRAG_URLS" ]; then
  echo "No fragment warnings to verify — nothing to do."
  exit 0
fi

FRAG_URLS="$EXT_FRAG_URLS"

# Cache DOM per base URL (many anchors can share a page)
CACHE_DIR=$(mktemp -d)
trap 'rm -rf "$CACHE_DIR"' EXIT

# Percent-decode a couple of common cases so attr="..." comparisons line up.
decode_frag() { printf '%s' "$1" | sed 's/%20/ /g; s/%22/"/g; s/%29/)/g'; }

PASSED_URLS=()

# --- External anchors (headless render or curl) ---
if [ -n "$FRAG_URLS" ]; then
  FRAG_COUNT=$(printf '%s\n' "$FRAG_URLS" | grep -c . || true)
  echo "Verifying $FRAG_COUNT external fragment anchor(s)..."
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    base="${url%%#*}"
    frag_decoded=$(decode_frag "${url#*#}")

    cache_key=$(printf '%s' "$base" | tr -c '[:alnum:]' '_')
    dom_file="$CACHE_DIR/$cache_key.html"
    [ -f "$dom_file" ] || fetch_dom "$base" > "$dom_file" || true

    if frag_in_dom "$dom_file" "$frag_decoded"; then
      echo "  RESOLVED: $url"
      PASSED_URLS+=("$url")
    else
      echo "  STILL BROKEN: $url"
    fi
  done <<< "$FRAG_URLS"
fi

# --- Local built-page anchors (static HTML only; opt-in) ---
if [ -n "$LOCAL_FRAG_URLS" ]; then
  LOCAL_COUNT=$(printf '%s\n' "$LOCAL_FRAG_URLS" | grep -c . || true)
  echo "Verifying $LOCAL_COUNT local fragment anchor(s) against $PUBLIC_DIR (static HTML)..."
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    base="${url%%#*}"
    frag_decoded=$(decode_frag "${url#*#}")

    # file:///abs/.../public/docs/x/index.html -> $PUBLIC_DIR/docs/x/index.html
    rel="${base#file://}"
    if [[ "$rel" == *"/public/"* ]]; then
      local_file="$PUBLIC_DIR/${rel#*/public/}"
    else
      local_file="$rel"
    fi
    # A directory-style URL resolves to its index.html.
    [ -d "$local_file" ] && local_file="$local_file/index.html"
    [[ "$local_file" != *.html && -f "$local_file/index.html" ]] && local_file="$local_file/index.html"

    if [ -f "$local_file" ] && frag_in_dom "$local_file" "$frag_decoded"; then
      echo "  RESOLVED: $url"
      PASSED_URLS+=("$url")
    else
      echo "  STILL BROKEN: $url"
    fi
  done <<< "$LOCAL_FRAG_URLS"
fi

if [ ${#PASSED_URLS[@]} -eq 0 ]; then
  echo "No fragment warnings verified as resolvable — JSON unchanged."
  exit 0
fi

echo "Removing ${#PASSED_URLS[@]} verified anchor(s) from JSON..."

# Prune passed URLs from error_map/fail_map in a SINGLE pass — O(map size),
# independent of how many anchors passed (the old per-URL filter was
# O(passed x map size), which got slow on large reports). The URL list is passed
# via --argjson as a lookup set, so nothing is interpolated into the jq program.
# Then recompute .errors from what remains, since lychee's top-level count
# double-counts a URL across pages (same approach as curl-retry-failures.sh).
PASSED_JSON=$(printf '%s\n' "${PASSED_URLS[@]}" | jq -R . | jq -s .)

TMP_FILE=$(mktemp)
jq --argjson passed "$PASSED_JSON" '
  def prune($set):
    with_entries(
      (.value |= (
        if type == "array" then map(select($set[(.url // .uri // "")] | not))
        elif type == "object" then (if $set[(.url // .uri // "")] then null else . end)
        elif type == "string" then (if $set[.] then null else . end)
        else . end
      ))
      | select((.value != null)
               and (if (.value | type) == "array" then (.value | length) > 0 else true end))
    );
  ($passed | map({key: ., value: true}) | from_entries) as $set
  | (if .error_map then .error_map |= prune($set) else . end)
  | (if .fail_map then .fail_map |= prune($set) else . end)
  | (if .errors then .errors = ([.error_map[]? | if type == "array" then length elif . == null then 0 else 1 end] | add // 0) else . end)
' "$JSON_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$JSON_FILE"

echo "Done. Removed ${#PASSED_URLS[@]} verified anchor(s)."
