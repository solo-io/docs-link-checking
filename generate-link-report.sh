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

  # Solo cross-product /latest/ link resolving to a specific version
  # (docs.solo.io/<product>/latest/<rest> → /<product>/<X.Y.x>/<rest>). Using
  # /latest/ is intentional (auto-tracks the newest version), so this exact
  # redirect is expected. Skip ONLY when the target segment is a real version
  # (X.Y.x) AND the rest of the path is unchanged — so a /latest/ link that
  # redirects somewhere else (login, a renamed path, etc.) is still reported,
  # and a genuinely broken /latest/<page> still errors (404, not a redirect).
  if [[ "$orig_lower" =~ docs\.solo\.io/([^/]+)/latest/(.*)$ ]]; then
    local _prod="${BASH_REMATCH[1]}" _rest="${BASH_REMATCH[2]}"
    if [[ "$final_lower" =~ docs\.solo\.io/${_prod}/[0-9]+\.[0-9]+\.x/(.*)$ ]]; then
      [ "${BASH_REMATCH[1]}" = "$_rest" ] && return 0
    fi
  fi

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
