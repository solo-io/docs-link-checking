#!/usr/bin/env bash
# Generate a markdown link report from Lychee JSON output.
# Puts newest versions first (e.g. 2.12 before 2.9) so the issue body stays under
# GitHub's limit while showing the most relevant links.
#
# Optional 3rd arg: PUBLIC_DIR (e.g. workspace/public). When set, broken file:// links
# where the source page and the broken URL refer to the same page in different versions
# (e.g. version-switcher links) are excluded from the report. Broken links to a different
# page, or within the same version, are always reported.
#
# Optional 4th arg: when set to "pr", the script diffs against origin/main to
# find changed content/asset files and scopes results to only include:
#   1. Broken links in files that were changed (source matches a changed file)
#   2. Broken links to files that were changed (target matches a changed file)
# Asset files are resolved to the content pages that reuse them via
# find-asset-users.py (located next to this script).
set -euo pipefail

JSON_FILE="${1:?Usage: generate-link-report.sh <lychee.json> [output.md] [public_dir] [pr]}"
OUTPUT_FILE="${2:-}"
PUBLIC_DIR="${3:-}"
PR_MODE="${4:-}"

# Build slug list from changed content files (if in PR mode).
# Slugs are the path fragments that appear in public/ URLs:
#   content/docs/foo/bar.md    -> docs/foo/bar/
#   content/docs/foo/_index.md -> docs/foo/
CHANGED_SLUGS=()
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "$PR_MODE" ]; then
  # Get changed content and asset files relative to the base branch
  PR_CHANGED_FILES=$(git diff --name-only origin/main...HEAD -- content/ assets/ 2>/dev/null \
    | sort -u || true)
  # Resolve asset files to the content pages that reuse them
  CHANGED_CONTENT_FILES=$(echo "$PR_CHANGED_FILES" \
    | python3 "$SCRIPT_DIR/find-asset-users.py" --repo-root "$(git rev-parse --show-toplevel)" --content-only - 2>/dev/null || true)
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    rel="${file#content/}"
    # Hugo drops the default language prefix (e.g. en/) from output paths,
    # so strip it to match public/ paths.
    rel="${rel#en/}"
    if [[ "$rel" == */_index.md ]]; then
      slug="${rel%/_index.md}/"
    elif [[ "$rel" == *.md ]]; then
      slug="${rel%.md}/"
    else
      continue
    fi
    CHANGED_SLUGS+=("$slug")
  done <<< "$CHANGED_CONTENT_FILES"
fi

# Returns 0 if the path segment looks like a docs version (e.g. 2.9, 2.12.x,
# v2.1, 1.0.0, main, latest, nightly, dev, stable, edge). Used to guard the
# version-drift filter below so it only fires on genuinely versioned sites.
# Non-versioned sites (e.g. ambientmesh.io, whose paths are
# public/docs/<section>/<page> with no version segment) would otherwise have
# same-named pages in different sections wrongly suppressed as version-switcher
# links.
looks_like_version() {
  [[ "$1" =~ ^v?[0-9]+(\.[0-9]+)*(\.x)?$ ]] && return 0
  case "$1" in
    main|latest|nightly|dev|stable|edge) return 0 ;;
  esac
  return 1
}

# Returns 0 (match) if the given path contains any changed-file slug.
matches_changed_file() {
  local path="$1"
  for slug in "${CHANGED_SLUGS[@]}"; do
    [[ "$path" == *"$slug"* ]] && return 0
  done
  return 1
}

if [ ! -f "$JSON_FILE" ]; then
  echo "JSON file not found: $JSON_FILE" >&2
  exit 1
fi

# Fold timed-out checks into error_map. Lychee keeps them in a separate
# timeout_map that the report never read, so a URL that timed out on a single page
# was reported nowhere at all. See fold-timeouts.sh.
FOLD_SCRIPT="$SCRIPT_DIR/fold-timeouts.sh"
if [ -f "$FOLD_SCRIPT" ]; then
  chmod +x "$FOLD_SCRIPT"
  "$FOLD_SCRIPT" "$JSON_FILE" || true
fi

# Resolve lychee's "Error (cached)" placeholder into the real underlying status
# (timeout, 404, fragment, ...). Lychee checks each URL once per run and reports
# every later occurrence as a bare cached error, which is both untriageable in the
# report and unclassifiable by the retry step below. See resolve-cached-status.sh.
RESOLVE_SCRIPT="$SCRIPT_DIR/resolve-cached-status.sh"
if [ -f "$RESOLVE_SCRIPT" ]; then
  chmod +x "$RESOLVE_SCRIPT"
  "$RESOLVE_SCRIPT" "$JSON_FILE" || true
fi

# Retry flaky failures with curl before generating the report.
# Failures whose status looks transient (timeout, dropped connection, 429), plus
# any URL matching curl-retry-patterns.txt, are re-checked with a single curl
# request. This removes false positives from the JSON before we count errors.
RETRY_SCRIPT="$SCRIPT_DIR/curl-retry-failures.sh"
if [ -x "$RETRY_SCRIPT" ] || [ -f "$RETRY_SCRIPT" ]; then
  chmod +x "$RETRY_SCRIPT"
  "$RETRY_SCRIPT" "$JSON_FILE" || true
fi

# Verify broken-anchor warnings against the real (optionally JS-rendered) page and
# prune the ones that actually resolve. lychee only recognizes id=/name= anchors in
# static HTML, so it flags anchors exposed via data-key or injected by JS (for
# example legal.solo.io) even though they work in a browser. This checks them for
# real instead of blanket-ignoring the URL. See verify-anchors.sh.
ANCHOR_SCRIPT="$SCRIPT_DIR/verify-anchors.sh"
if [ -x "$ANCHOR_SCRIPT" ] || [ -f "$ANCHOR_SCRIPT" ]; then
  chmod +x "$ANCHOR_SCRIPT"
  # Pass PUBLIC_DIR so verify-anchors can also check local built-page anchors
  # (id/name/data-key/data-ks-path) against the static HTML.
  "$ANCHOR_SCRIPT" "$JSON_FILE" "$PUBLIC_DIR" || true
fi

# Counts from Lychee JSON (we report unique errors so the summary matches the list below)
REDIRECTS=$(jq -r '.redirects // (.redirect_map | length) // 0' "$JSON_FILE")
if [ "$REDIRECTS" = "null" ]; then REDIRECTS=0; fi

# Failed URLs: extract (url, details, source) from .error_map so we can show where each
# link was found and classify fragment warnings separately.
FAIL_SECTION=""
WARN_SECTION=""
UNIQUE_ERRORS=0
UNIQUE_WARNINGS=0
RAW_ERRORS=$(jq -r '.errors // (.error_map | length) // 0' "$JSON_FILE")
if [ "$RAW_ERRORS" = "null" ]; then RAW_ERRORS=0; fi
if [ "${RAW_ERRORS:-0}" -gt 0 ]; then
  # Output "url\tdetails\tsource" for every (source, url) pair
  FAIL_ENTRIES=$(jq -r '
    (.error_map // .fail_map // {} | to_entries[] |
      .key as $source |
      .value as $v |
      if ($v | type) == "string" then "\($v)\t\t\($source)"
      elif ($v | type) == "object" then "\($v.url // $v.uri // .key)\t\($v.status.details // $v.status.text // $v.details // "")\t\($source)"
      elif ($v | type) == "array" then ($v[] | "\(.url // .uri // "")\t\(.status.details // .status.text // .details // "")\t\($source)" | select(length > 0))
      else "\(.key)\t\t\($source)"
      end
    ) | select(split("\t")[0] | length > 0)
  ' "$JSON_FILE" 2>/dev/null || true)
  if [ -n "$FAIL_ENTRIES" ]; then
    # Apply version-drift filter (same as before)
    if [ -n "$PUBLIC_DIR" ] && [ -d "$PUBLIC_DIR" ]; then
      _FILT_TMP=$(mktemp)
      while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        url=$(printf '%s' "$entry" | cut -f1)
        src=$(printf '%s' "$entry" | cut -f3-)

        # Normalize file:// URLs to public/... paths
        url_path="$url"
        if [[ "$url" == file:///* ]]; then
          _rest="${url#file://}"
          [[ "$_rest" == *"/public/"* ]] && url_path="public/${_rest#*/public/}" || url_path="${_rest#/}"
        fi
        src_path="$src"
        if [[ "$src" == file:///* ]]; then
          _rest="${src#file://}"
          [[ "$_rest" == *"/public/"* ]] && src_path="public/${_rest#*/public/}" || src_path="${_rest#/}"
        fi

        exclude=0
        # Suppress only cross-version links where the broken URL points to the same page
        # as its source but in a different version (e.g. version-switcher links).
        # Links to a different page, or to the same version, are always reported.
        if [[ "$url_path" == public/*/*/* ]] && [[ "$src_path" == public/*/*/* ]]; then
          url_product=$(printf '%s' "$url_path" | cut -d/ -f2)
          url_version=$(printf '%s' "$url_path" | cut -d/ -f3)
          url_rel="${url_path#public/$url_product/$url_version/}"

          src_product=$(printf '%s' "$src_path" | cut -d/ -f2)
          src_version=$(printf '%s' "$src_path" | cut -d/ -f3)
          src_rel="${src_path#public/$src_product/$src_version/}"
          src_rel_norm="${src_rel%/index.html}"

          if [ -n "$url_rel" ] && [ -n "$src_rel_norm" ] \
             && [ "$url_product" = "$src_product" ] \
             && [ "$url_version" != "$src_version" ] \
             && looks_like_version "$url_version" \
             && looks_like_version "$src_version" \
             && [ "$url_rel" = "$src_rel_norm" ]; then
            exclude=1
          fi
        fi

        [ "$exclude" -eq 0 ] && printf '%s\n' "$entry" >> "$_FILT_TMP"
      done <<< "$FAIL_ENTRIES"
      FAIL_ENTRIES=$(cat "$_FILT_TMP")
      rm -f "$_FILT_TMP"
    fi

    # Scope to PR-changed files: keep entries where source or target matches a changed file
    if [ ${#CHANGED_SLUGS[@]} -gt 0 ]; then
      _FILT_TMP=$(mktemp)
      while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        url=$(printf '%s' "$entry" | cut -f1)
        src=$(printf '%s' "$entry" | cut -f3-)
        # Include if source (edited file has broken link) or target (link points to edited file) matches
        if matches_changed_file "$src" || matches_changed_file "$url"; then
          printf '%s\n' "$entry" >> "$_FILT_TMP"
        fi
      done <<< "$FAIL_ENTRIES"
      FAIL_ENTRIES=$(cat "$_FILT_TMP")
      rm -f "$_FILT_TMP"
    fi

    # Drop false-positive fragment errors for GitHub line-range anchors (#L123 / #L123-L456).
    # Lychee can't resolve these anchors but the links are valid.
    FAIL_ENTRIES=$(echo "$FAIL_ENTRIES" | awk -F'\t' '!($1 ~ /#L[0-9]/ && tolower($2) ~ /fragment/)' || true)

    # Split into errors and warnings. A URL goes to warnings if ANY entry for
    # that URL mentions "fragment" in its details (broken anchor), so the same
    # URL doesn't appear in both sections.
    FRAGMENT_URLS=$(echo "$FAIL_ENTRIES" | awk -F'\t' 'tolower($2) ~ /fragment/ { print $1 }' | sort -u || true)
    if [ -n "$FRAGMENT_URLS" ]; then
      # Write fragment URLs to a temp file so awk can read them without hitting
      # the -v newline limitation (awk -v does not allow literal newlines in a
      # variable value, which silently empties ERROR_ENTRIES / WARN_ENTRIES).
      _FRAG_TMP=$(mktemp)
      printf '%s\n' "$FRAGMENT_URLS" > "$_FRAG_TMP"
      ERROR_ENTRIES=$(echo "$FAIL_ENTRIES" | awk -F'\t' \
        'NR==FNR { urls[$0]=1; next } !($1 in urls)' "$_FRAG_TMP" - || true)
      WARN_ENTRIES=$(echo "$FAIL_ENTRIES" | awk -F'\t' \
        'NR==FNR { urls[$0]=1; next } ($1 in urls)' "$_FRAG_TMP" - || true)
      rm -f "$_FRAG_TMP"
    else
      ERROR_ENTRIES="$FAIL_ENTRIES"
      WARN_ENTRIES=""
    fi

    # --- Build Errors section ---
    ERROR_URLS=$(echo "$ERROR_ENTRIES" | cut -f1 | sort -u -V -r | grep . || true)
    UNIQUE_ERRORS=$(echo "$ERROR_URLS" | grep -c . || true)
    if [ -n "$ERROR_ENTRIES" ] && [ "${UNIQUE_ERRORS:-0}" -gt 0 ]; then
      _FAIL_TMP=$(mktemp)
      printf '## Errors (newest versions first)\n\n' > "$_FAIL_TMP"
      MAX_SOURCES=5
      while IFS= read -r url; do
        [ -z "$url" ] && continue
        sources=$(echo "$ERROR_ENTRIES" | awk -F'\t' -v u="$url" '$1==u { print $3 }' | sort -u)
        source_count=$(echo "$sources" | grep -c . || true)
        # Extract the first non-empty status/details for this URL
        status_detail=$(echo "$ERROR_ENTRIES" | awk -F'\t' -v u="$url" '$1==u && $2!="" { print $2; exit }' 2>/dev/null || true)
        # Shorten verbose network error messages
        [[ "$status_detail" == *"Network error:"* ]] && status_detail=$(echo "$status_detail" | sed 's/ (error .*//' || true)
        display_url="$url"
        if [[ "$url" == file:///* ]]; then
          rest="${url#file://}"
          [[ "$rest" == *"/public/"* ]] && display_url="public/${rest#*/public/}" || display_url="${rest#/}"
        fi
        if [ -n "$status_detail" ]; then
          printf -- '- [ ] `%s` — %s\n' "$display_url" "$status_detail" >> "$_FAIL_TMP"
        else
          printf -- '- [ ] `%s`\n' "$display_url" >> "$_FAIL_TMP"
        fi
        first=1
        n=0
        found_on=""
        while IFS= read -r src; do
          [ -z "$src" ] && continue
          [[ "$src" == file:///* ]] && src="${src#file://}" && [[ "$src" == *"/public/"* ]] && src="public/${src#*/public/}"
          n=$((n+1))
          if [ "$n" -le "$MAX_SOURCES" ]; then
            [ "$first" -eq 1 ] && found_on="  Found on: \`$src\`" && first=0 || found_on="$found_on, \`$src\`"
          fi
        done <<< "$sources"
        [ "$source_count" -gt "$MAX_SOURCES" ] && found_on="$found_on, and $((source_count - MAX_SOURCES)) more"
        [ -n "$found_on" ] && printf '%s\n' "$found_on" >> "$_FAIL_TMP"
      done <<< "$ERROR_URLS"
      FAIL_SECTION=$(cat "$_FAIL_TMP")
      rm -f "$_FAIL_TMP"
    fi

    # --- Build Warnings section (fragment anchor errors) ---
    WARN_URLS=$(echo "$WARN_ENTRIES" | cut -f1 | sort -u -V -r | grep . || true)
    UNIQUE_WARNINGS=$(echo "$WARN_URLS" | grep -c . || true)
    if [ -n "$WARN_ENTRIES" ] && [ "${UNIQUE_WARNINGS:-0}" -gt 0 ]; then
      _WARN_TMP=$(mktemp)
      printf '## Warnings — broken anchors (newest versions first)\n\n' > "$_WARN_TMP"
      MAX_SOURCES=5
      while IFS= read -r url; do
        [ -z "$url" ] && continue
        sources=$(echo "$WARN_ENTRIES" | awk -F'\t' -v u="$url" '$1==u { print $3 }' | sort -u)
        source_count=$(echo "$sources" | grep -c . || true)
        status_detail=$(echo "$WARN_ENTRIES" | awk -F'\t' -v u="$url" '$1==u && $2!="" { print $2; exit }' 2>/dev/null || true)
        [[ "$status_detail" == *"Network error:"* ]] && status_detail=$(echo "$status_detail" | sed 's/ (error .*//' || true)
        display_url="$url"
        if [[ "$url" == file:///* ]]; then
          rest="${url#file://}"
          [[ "$rest" == *"/public/"* ]] && display_url="public/${rest#*/public/}" || display_url="${rest#/}"
        fi
        if [ -n "$status_detail" ]; then
          printf -- '- [ ] `%s` — %s\n' "$display_url" "$status_detail" >> "$_WARN_TMP"
        else
          printf -- '- [ ] `%s`\n' "$display_url" >> "$_WARN_TMP"
        fi
        first=1
        n=0
        found_on=""
        while IFS= read -r src; do
          [ -z "$src" ] && continue
          [[ "$src" == file:///* ]] && src="${src#file://}" && [[ "$src" == *"/public/"* ]] && src="public/${src#*/public/}"
          n=$((n+1))
          if [ "$n" -le "$MAX_SOURCES" ]; then
            [ "$first" -eq 1 ] && found_on="  Found on: \`$src\`" && first=0 || found_on="$found_on, \`$src\`"
          fi
        done <<< "$sources"
        [ "$source_count" -gt "$MAX_SOURCES" ] && found_on="$found_on, and $((source_count - MAX_SOURCES)) more"
        [ -n "$found_on" ] && printf '%s\n' "$found_on" >> "$_WARN_TMP"
      done <<< "$WARN_URLS"
      WARN_SECTION=$(cat "$_WARN_TMP")
      rm -f "$_WARN_TMP"
    fi

  else
    # .errors is > 0 but no error URLs could be enumerated from .error_map. This
    # usually means the top-level count is stale/inflated relative to error_map
    # (e.g. after the curl-retry step emptied the listed entries), not that there
    # are real broken links. Emit nothing reader-facing — UNIQUE_ERRORS stays 0 so
    # the summary table reports "Errors: 0" truthfully. Log a diagnostic to stderr
    # for maintainers in case the JSON shape really did change.
    echo "Note: .errors=$RAW_ERRORS but no URLs enumerable from .error_map; reporting 0 errors. Top-level keys: $(jq -r "keys | join(\", \")" "$JSON_FILE" 2>/dev/null || echo "?")." >&2
    FAIL_SECTION=""
  fi
fi

# Returns 0 if a path segment looks like a version: 1.2, 1.2.3, 1.2.x, v1.15.4,
# or a dated docs snapshot (2026-07-28). A bare number (/docs/8/) is deliberately
# NOT treated as a version, since that is more often a real page.
is_version_segment() {
  [[ "$1" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?(\.x)?$ ]] && return 0
  [[ "$1" =~ ^v[0-9]+$ ]] && return 0
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && return 0
  return 1
}

# Returns 0 if the redirect is a version-pointer redirect: an unversioned or
# /latest/ URL resolving to the same page under a version segment. Sites that do
# this include docs.solo.io (/istio/latest/ → /istio/1.30.x/), jaegertracing.io
# (/docs/latest/ → /docs/2.20/), and modelcontextprotocol.io (/docs/tools/inspector
# → /docs/2026-07-28/tools/inspector). Keeping the source URL is intentional
# because it auto-tracks the current version, so the redirect is expected forever
# and reporting it is pure noise.
#
# Deliberately narrow: the host must be unchanged and the path must differ by
# exactly one version segment, either substituted for "latest" or inserted. A
# renamed page, a moved domain, a login redirect, or a version-to-version bump
# (1.2 → 1.3, which is a stale pin worth fixing) all still get reported. A URL
# that is genuinely gone still 404s, which is an error rather than a redirect.
is_version_pointer_redirect() {
  local o="${1#*://}" f="${2#*://}"
  o="${o%%\?*}"; f="${f%%\?*}"
  o="${o%/}"; f="${f%/}"

  local -a os fs
  IFS='/' read -r -a os <<< "$o"
  IFS='/' read -r -a fs <<< "$f"

  # Index 0 is the host. A host change is a real move, not a version pointer.
  [ "${os[0]}" = "${fs[0]}" ] || return 1

  local n=${#os[@]} m=${#fs[@]} i j
  if [ "$m" -eq "$n" ]; then
    # Substitution: /latest/ (or /stable/, /current/) replaced by a version.
    local diff=-1
    for ((i = 0; i < n; i++)); do
      if [ "${os[i]}" != "${fs[i]}" ]; then
        [ "$diff" -ge 0 ] && return 1
        diff=$i
      fi
    done
    [ "$diff" -lt 0 ] && return 1
    case "${os[diff]}" in
      latest|stable|current) ;;
      *) return 1 ;;
    esac
    is_version_segment "${fs[diff]}"
    return $?
  elif [ "$m" -eq "$((n + 1))" ]; then
    # Insertion: a version segment added, the rest of the path unchanged.
    for ((i = 0; i < n; i++)); do
      if [ "${os[i]}" != "${fs[i]}" ]; then
        is_version_segment "${fs[i]}" || return 1
        for ((j = i; j < n; j++)); do
          [ "${os[j]}" = "${fs[j + 1]}" ] || return 1
        done
        return 0
      fi
    done
    # Version segment appended at the end (/specification → /specification/2025-11-25).
    is_version_segment "${fs[n]}"
    return $?
  fi
  return 1
}

# Returns 0 (skip) if the redirect is caused by a known ignorable server-side pattern.
skip_redirect() {
  local original="$1" final="$2"
  local orig_lower final_lower
  orig_lower=$(printf '%s' "$original" | tr '[:upper:]' '[:lower:]')
  final_lower=$(printf '%s' "$final" | tr '[:upper:]' '[:lower:]')

  # Only difference is a trailing slash
  [ "${original%/}" = "${final%/}" ] && return 0

  # Only differences are in the query string (everything after ?)
  local orig_base final_base
  orig_base="${original%%\?*}"
  final_base="${final%%\?*}"
  [[ "$final" == *"?"* ]] && [ "$orig_base" = "$final_base" ] && return 0

  # Locale redirect: en_us or en-us in redirect but not original
  [[ "$final_lower" == *"en_us"* ]] && [[ "$orig_lower" != *"en_us"* ]] && return 0
  [[ "$final_lower" == *"en-us"* ]] && [[ "$orig_lower" != *"en-us"* ]] && return 0

  # Locale redirect: /en or /en/ path segment added in redirect but not original
  [[ "$final_lower" == *"/en/"* || "$final_lower" == *"/en" ]] \
    && [[ "$orig_lower" != *"/en/"* ]] \
    && [[ "$orig_lower" != *"/en" ]] \
    && return 0

  # Auth redirect: login or signin in redirect but not original
  [[ "$final_lower" == *"login"* ]] && [[ "$orig_lower" != *"login"* ]] && return 0
  [[ "$final_lower" == *"signin"* ]] && [[ "$orig_lower" != *"signin"* ]] && return 0

  # Home redirect: /home in redirect but not original
  [[ "$final_lower" == *"/home"* ]] && [[ "$orig_lower" != *"/home"* ]] && return 0

  # agentgateway.dev/examples/ intentionally redirects to raw.githubusercontent.com
  [[ "$orig_lower" == *"agentgateway.dev/examples/"* ]] \
    && [[ "$final_lower" == *"raw.githubusercontent.com/"* ]] \
    && return 0

  # Version-pointer redirect (docs.solo.io/<product>/latest/, jaegertracing.io
  # /docs/latest/, modelcontextprotocol.io/docs/ → dated snapshot, and so on).
  is_version_pointer_redirect "$orig_lower" "$final_lower" && return 0

  # Go vanity import path redirecting to its GitHub repo (e.g.
  # sigs.k8s.io/gateway-api → github.com/kubernetes-sigs/gateway-api). The
  # sigs.k8s.io form is the correct one to keep (it's what `go get` uses).
  [[ "$orig_lower" == *"sigs.k8s.io/gateway-api"* ]] \
    && [[ "$final_lower" == *"github.com/kubernetes-sigs/gateway-api"* ]] \
    && return 0

  return 1
}

# Redirects: Lychee uses .redirect_map (key=source path, value=array of { url, status: { redirects: { redirects: [{ url, code }, ...] } } })
# Process redirects before building the summary so the displayed count matches.
REDIRECT_SECTION=""
DISPLAYED_REDIRECTS=0
if [ "${REDIRECTS:-0}" -gt 0 ]; then
  # Include source page (redirect_map key) as third field so we can show "Found on".
  # Lychee ≥0.15 redirect_map entries use { origin, redirects: [{url, code}] };
  # older builds used { url, status: { redirects: { redirects: [{url,code}] } } }.
  # Accept both shapes so the report works across lychee versions.
  REDIRECT_ENTRIES=$(jq -r '
    (.redirect_map // {} | to_entries[] |
      .key as $source |
      .value[]? |
      # Prefer .origin (current lychee format); fall back to .url (older format)
      ((.origin // .url) // "") as $original |
      # Prefer .redirects[-1].url; fall back to nested .status path
      ((.redirects[-1].url // .status.redirects.redirects[-1].url // .origin // .url) // "") as $final |
      "\($original)\t\($final)\t\($source)"
    ) | select(length > 0)
  ' "$JSON_FILE" 2>/dev/null || true)
  # Scope redirects to PR-changed files
  if [ -n "$REDIRECT_ENTRIES" ] && [ ${#CHANGED_SLUGS[@]} -gt 0 ]; then
    _FILT_TMP=$(mktemp)
    while IFS= read -r entry; do
      [ -z "$entry" ] && continue
      url=$(printf '%s' "$entry" | cut -f1)
      src=$(printf '%s' "$entry" | cut -f3-)
      if matches_changed_file "$src" || matches_changed_file "$url"; then
        printf '%s\n' "$entry" >> "$_FILT_TMP"
      fi
    done <<< "$REDIRECT_ENTRIES"
    REDIRECT_ENTRIES=$(cat "$_FILT_TMP")
    rm -f "$_FILT_TMP"
  fi

  if [ -n "$REDIRECT_ENTRIES" ]; then
    _REDIR_TMP=$(mktemp)
    printf '## Redirects (newest versions first)\n\n' > "$_REDIR_TMP"
    MAX_SOURCES=5
    REDIRECT_URLS=$(echo "$REDIRECT_ENTRIES" | cut -f1 | sort -u -V -r)
    while IFS= read -r original; do
      [ -z "$original" ] && continue
      final=$(echo "$REDIRECT_ENTRIES" | awk -F'\t' -v u="$original" 'BEGIN{f=0} $1==u && !f { print $2; f=1 }')

      # Skip ignorable server-side redirect patterns
      skip_redirect "$original" "$final" && continue

      DISPLAYED_REDIRECTS=$((DISPLAYED_REDIRECTS + 1))
      sources=$(echo "$REDIRECT_ENTRIES" | awk -F'\t' -v u="$original" '$1==u { print $3 }' | sort -u)
      source_count=$(echo "$sources" | grep -c . || true)
      if [ -n "$final" ] && [ "$original" != "$final" ]; then
        printf -- '- [ ] `%s` → `%s`\n' "$original" "$final" >> "$_REDIR_TMP"
      else
        printf -- '- [ ] `%s` (redirect)\n' "$original" >> "$_REDIR_TMP"
      fi
      first=1
      n=0
      found_on=""
      while IFS= read -r src; do
        [ -z "$src" ] && continue
        [[ "$src" == file:///* ]] && src="${src#file://}" && [[ "$src" == *"/public/"* ]] && src="public/${src#*/public/}"
        n=$((n+1))
        if [ "$n" -le "$MAX_SOURCES" ]; then
          [ "$first" -eq 1 ] && found_on="  Found on: \`$src\`" && first=0 || found_on="$found_on, \`$src\`"
        fi
      done <<< "$sources"
      [ "$source_count" -gt "$MAX_SOURCES" ] && found_on="$found_on, and $((source_count - MAX_SOURCES)) more"
      [ -n "$found_on" ] && printf '%s\n' "$found_on" >> "$_REDIR_TMP"
    done <<< "$REDIRECT_URLS"
    if [ "$DISPLAYED_REDIRECTS" -eq 0 ]; then
      REDIRECT_SECTION=""
    else
      REDIRECT_SECTION=$(cat "$_REDIR_TMP")
    fi
    rm -f "$_REDIR_TMP"
  else
    DISPLAYED_REDIRECTS="$REDIRECTS"
    REDIRECT_SECTION="## Redirects

$REDIRECTS link(s) redirect. (Details not in JSON; check Lychee output.)
"
  fi
fi

# --- Broken remote includes (github / github-yaml shortcode fetch failures) ---
# Lychee cannot see these when the include sits inside a code fence: the
# "Unable to load code from <a href=…>" error renders inside <pre>, and Lychee
# skips anchors in code blocks. check-broken-includes.sh greps the built HTML
# for that marker (parse-independent). Fold its findings into the error count
# and report so they surface, create issues, and gate PRs exactly like a broken
# link — no separate workflow step needed. Runs only when a PUBLIC_DIR (arg 3,
# the built tree) was passed. Scans ALL versions: unlike the Lychee version
# excludes (which skip retired versions to avoid external link-rot noise), a
# broken include is a severe, rare, trivially-fixable rendering break worth
# catching everywhere — so it deliberately does not inherit those excludes.
INCLUDE_SECTION=""
INCLUDE_SCRIPT="$SCRIPT_DIR/check-broken-includes.sh"
# Invoke via `bash` (not requiring the executable bit, which may not survive a
# sparse/zip checkout) and guard on file existence.
if [ -n "$PUBLIC_DIR" ] && [ -d "$PUBLIC_DIR" ] && [ -f "$INCLUDE_SCRIPT" ]; then
  INCLUDE_FINDINGS=$(bash "$INCLUDE_SCRIPT" "$PUBLIC_DIR" 2>/dev/null || true)
  if [ -n "$INCLUDE_FINDINGS" ]; then
    INCLUDE_COUNT=$(printf '%s\n' "$INCLUDE_FINDINGS" | grep -c . || true)
    UNIQUE_ERRORS=$((UNIQUE_ERRORS + INCLUDE_COUNT))
    _INC_TMP=$(mktemp)
    printf '## Broken remote includes (%s)\n\n' "$INCLUDE_COUNT" > "$_INC_TMP"
    printf 'The `github` / `github-yaml` shortcode failed to fetch these URLs at build time. They are invisible to Lychee when the include sits inside a code fence, so they are scanned separately (check-broken-includes.sh). Fix the URL or the example path in the page source.\n\n' >> "$_INC_TMP"
    while IFS=$'\t' read -r rel url; do
      [ -z "$rel" ] && continue
      printf -- '- `%s` → %s\n' "$rel" "$url" >> "$_INC_TMP"
    done <<< "$INCLUDE_FINDINGS"
    INCLUDE_SECTION=$(cat "$_INC_TMP")
    rm -f "$_INC_TMP"
  fi
fi

# Summary uses unique error count and displayed redirect count so both match the lists below
SUMMARY="## Link checking summary for $PRODUCT_NAME

| | Count |
|-|------:|
| Errors | $UNIQUE_ERRORS |
| Warnings (broken anchors) | $UNIQUE_WARNINGS |
| Redirects | $DISPLAYED_REDIRECTS |
"

REPORT="${SUMMARY}
${FAIL_SECTION}
${INCLUDE_SECTION}
${WARN_SECTION}
${REDIRECT_SECTION}"

# Signal whether there are any reportable issues after filtering.
# Workflows use this to skip issue creation when all counts are 0.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  if [ "${UNIQUE_ERRORS:-0}" -gt 0 ] || [ "${UNIQUE_WARNINGS:-0}" -gt 0 ] || [ "${DISPLAYED_REDIRECTS:-0}" -gt 0 ]; then
    echo "has_issues=true" >> "$GITHUB_OUTPUT"
  else
    echo "has_issues=false" >> "$GITHUB_OUTPUT"
  fi
fi

if [ -n "$OUTPUT_FILE" ]; then
  echo "$REPORT" > "$OUTPUT_FILE"
else
  echo "$REPORT"
fi
