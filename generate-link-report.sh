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

# Retry flaky failures with curl before generating the report.
# Domains in curl-retry-patterns.txt are known to drop connections under CI
# load but respond fine to a single curl request. This removes false positives
# from the JSON before we count errors.
RETRY_SCRIPT="$SCRIPT_DIR/curl-retry-failures.sh"
if [ -x "$RETRY_SCRIPT" ] || [ -f "$RETRY_SCRIPT" ]; then
  chmod +x "$RETRY_SCRIPT"
  "$RETRY_SCRIPT" "$JSON_FILE" || true
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
      FILTERED_ENTRIES=""
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
             && [ "$url_rel" = "$src_rel_norm" ]; then
            exclude=1
          fi
        fi

        [ "$exclude" -eq 0 ] && FILTERED_ENTRIES="${FILTERED_ENTRIES}${entry}"$'\n'
      done <<< "$FAIL_ENTRIES"
      FAIL_ENTRIES="$FILTERED_ENTRIES"
    fi

    # Scope to PR-changed files: keep entries where source or target matches a changed file
    if [ ${#CHANGED_SLUGS[@]} -gt 0 ]; then
      FILTERED_ENTRIES=""
      while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        url=$(printf '%s' "$entry" | cut -f1)
        src=$(printf '%s' "$entry" | cut -f3-)
        # Include if source (edited file has broken link) or target (link points to edited file) matches
        if matches_changed_file "$src" || matches_changed_file "$url"; then
          FILTERED_ENTRIES="${FILTERED_ENTRIES}${entry}"$'\n'
        fi
      done <<< "$FAIL_ENTRIES"
      FAIL_ENTRIES="$FILTERED_ENTRIES"
    fi

    # Drop false-positive fragment errors for GitHub line-range anchors (#L123 / #L123-L456).
    # Lychee can't resolve these anchors but the links are valid.
    FAIL_ENTRIES=$(echo "$FAIL_ENTRIES" | awk -F'\t' '!($1 ~ /#L[0-9]/ && tolower($2) ~ /fragment/)' || true)

    # Split into errors and warnings. A URL goes to warnings if ANY entry for
    # that URL mentions "fragment" in its details (broken anchor), so the same
    # URL doesn't appear in both sections.
    FRAGMENT_URLS=$(echo "$FAIL_ENTRIES" | awk -F'\t' 'tolower($2) ~ /fragment/ { print $1 }' | sort -u || true)
    if [ -n "$FRAGMENT_URLS" ]; then
      ERROR_ENTRIES=$(echo "$FAIL_ENTRIES" | awk -F'\t' -v frag="$FRAGMENT_URLS" '
        BEGIN { split(frag, a, "\n"); for (i in a) urls[a[i]]=1 }
        !($1 in urls)
      ' || true)
      WARN_ENTRIES=$(echo "$FAIL_ENTRIES" | awk -F'\t' -v frag="$FRAGMENT_URLS" '
        BEGIN { split(frag, a, "\n"); for (i in a) urls[a[i]]=1 }
        ($1 in urls)
      ' || true)
    else
      ERROR_ENTRIES="$FAIL_ENTRIES"
      WARN_ENTRIES=""
    fi

    # --- Build Errors section ---
    ERROR_URLS=$(echo "$ERROR_ENTRIES" | cut -f1 | sort -u -V -r | grep . || true)
    UNIQUE_ERRORS=$(echo "$ERROR_URLS" | grep -c . || true)
    if [ -n "$ERROR_ENTRIES" ] && [ "${UNIQUE_ERRORS:-0}" -gt 0 ]; then
      FAIL_SECTION="## Errors (newest versions first)

"
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
          FAIL_SECTION="${FAIL_SECTION}- [ ] \`${display_url}\` — ${status_detail}
"
        else
          FAIL_SECTION="${FAIL_SECTION}- [ ] \`${display_url}\`
"
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
        [ -n "$found_on" ] && FAIL_SECTION="${FAIL_SECTION}${found_on}
"
      done <<< "$ERROR_URLS"
    fi

    # --- Build Warnings section (fragment anchor errors) ---
    WARN_URLS=$(echo "$WARN_ENTRIES" | cut -f1 | sort -u -V -r | grep . || true)
    UNIQUE_WARNINGS=$(echo "$WARN_URLS" | grep -c . || true)
    if [ -n "$WARN_ENTRIES" ] && [ "${UNIQUE_WARNINGS:-0}" -gt 0 ]; then
      WARN_SECTION="## Warnings — broken anchors (newest versions first)

"
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
          WARN_SECTION="${WARN_SECTION}- [ ] \`${display_url}\` — ${status_detail}
"
        else
          WARN_SECTION="${WARN_SECTION}- [ ] \`${display_url}\`
"
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
        [ -n "$found_on" ] && WARN_SECTION="${WARN_SECTION}${found_on}
"
      done <<< "$WARN_URLS"
    fi

  else
    FAIL_SECTION="## Errors (newest versions first)

$RAW_ERRORS broken link(s) found. (URL list not in expected JSON shape. Top-level keys: $(jq -r "keys | join(\", \")" "$JSON_FILE" 2>/dev/null || echo "?").)
"
  fi
fi

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

  return 1
}

# Redirects: Lychee uses .redirect_map (key=source path, value=array of { url, status: { redirects: { redirects: [{ url, code }, ...] } } })
# Process redirects before building the summary so the displayed count matches.
REDIRECT_SECTION=""
DISPLAYED_REDIRECTS=0
if [ "${REDIRECTS:-0}" -gt 0 ]; then
  # Include source page (redirect_map key) as third field so we can show "Found on"
  REDIRECT_ENTRIES=$(jq -r '
    (.redirect_map // {} | to_entries[] |
      .key as $source |
      .value[]? |
      .url as $original |
      (.status.redirects.redirects[-1].url // .url) as $final |
      "\($original)\t\($final)\t\($source)"
    ) | select(length > 0)
  ' "$JSON_FILE" 2>/dev/null || true)
  # Scope redirects to PR-changed files
  if [ -n "$REDIRECT_ENTRIES" ] && [ ${#CHANGED_SLUGS[@]} -gt 0 ]; then
    FILTERED_ENTRIES=""
    while IFS= read -r entry; do
      [ -z "$entry" ] && continue
      url=$(printf '%s' "$entry" | cut -f1)
      src=$(printf '%s' "$entry" | cut -f3-)
      if matches_changed_file "$src" || matches_changed_file "$url"; then
        FILTERED_ENTRIES="${FILTERED_ENTRIES}${entry}"$'\n'
      fi
    done <<< "$REDIRECT_ENTRIES"
    REDIRECT_ENTRIES="$FILTERED_ENTRIES"
  fi

  if [ -n "$REDIRECT_ENTRIES" ]; then
    REDIRECT_SECTION="## Redirects (newest versions first)

"
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
        REDIRECT_SECTION="${REDIRECT_SECTION}- [ ] \`${original}\` → \`${final}\`
"
      else
        REDIRECT_SECTION="${REDIRECT_SECTION}- [ ] \`${original}\` (redirect)
"
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
      [ -n "$found_on" ] && REDIRECT_SECTION="${REDIRECT_SECTION}${found_on}
"
    done <<< "$REDIRECT_URLS"
    [ "$DISPLAYED_REDIRECTS" -eq 0 ] && REDIRECT_SECTION=""
  else
    DISPLAYED_REDIRECTS="$REDIRECTS"
    REDIRECT_SECTION="## Redirects

$REDIRECTS link(s) redirect. (Details not in JSON; check Lychee output.)
"
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
