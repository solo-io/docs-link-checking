#!/usr/bin/env bash
# Scan built HTML for FAILED remote includes emitted by the docs-theme-extras
# `github` / `github-yaml` shortcodes.
#
# On a failed remote fetch those shortcodes render:
#     <strong>Error:</strong> Unable to load code from <a href="URL">URL</a>
# Lychee, the link checker, cannot catch this: when the shortcode is used inside
# a code fence (e.g. a `cat <<EOF` heredoc) the error <a> lands inside <pre>, and
# Lychee skips anchors in code blocks — so a dead include URL ships a broken code
# block with zero link-check signal. This grep-based scan is parse-independent:
# it catches every failed include (embedded or standalone) by its error marker.
#
# CI builds cache-cold, so a URL that is dead at build time always renders this
# marker. By DEFAULT nothing is skipped — a broken include is broken content in
# any version. Pass a skip regex as the 2nd arg to mirror a consumer's own
# Lychee --exclude-path policy. NOTE the shapes differ: agentgateway excludes
# every numbered version (`docs/[^/]+/[0-9]`), but kgateway's CURRENT docs are
# numbered (envoy/2.1.x, 2.2.x) and it only retires envoy/2.0.x — so a
# blanket numbered-version skip would wrongly hide kgateway's live pages. There
# is no one-size default; scope per consumer via the 2nd arg when needed.
#
# Output:
#   stdout — one `<page>\t<url>` line per broken include (machine-readable, so a
#            caller such as generate-link-report.sh can fold these into its report)
#   stderr — a human summary + fix guidance
# Exit 1 if any broken include is found, 0 otherwise. Also writes
# `broken_includes=<n>` to $GITHUB_OUTPUT when set.
#
# Usage: check-broken-includes.sh <public_dir> [exclude_regex]
set -euo pipefail

PUBLIC_DIR="${1:?Usage: check-broken-includes.sh <public_dir> [exclude_regex]}"
[ -d "$PUBLIC_DIR" ] || { echo "check-broken-includes: '$PUBLIC_DIR' is not a directory" >&2; exit 2; }
EXCLUDE_REGEX="${2-}"

# Match the shortcode's exact failure output (quoted or Hugo-minified unquoted
# href). The `Unable to load code from <a href=` prefix is distinctive enough
# that a page legitimately containing the prose won't match.
MARKER='Unable to load code from <a href=["'\'']?[^"'\'' >]+'

found=0
human=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  file="${line%%:*}"
  match="${line#*:}"
  url="$(printf '%s' "$match" | sed -E 's/.*Unable to load code from <a href=["'\'']?//; s/["'\'' >].*//')"
  rel="${file#"$PUBLIC_DIR"/}"
  if [ -n "$EXCLUDE_REGEX" ] && printf '%s' "$rel" | grep -qE "$EXCLUDE_REGEX"; then continue; fi
  printf '%s\t%s\n' "$rel" "$url"          # machine-readable -> stdout
  human+="  - ${rel}: ${url}"$'\n'
  found=$((found + 1))
done < <(grep -roE "$MARKER" "$PUBLIC_DIR" --include='*.html' 2>/dev/null || true)

[ -n "${GITHUB_OUTPUT:-}" ] && echo "broken_includes=$found" >> "$GITHUB_OUTPUT"

if [ "$found" -gt 0 ]; then
  {
    echo "Broken remote includes ($found) — the github/github-yaml shortcode failed to fetch these URLs at build time:"
    printf '%s' "$human"
    echo ""
    echo "Fix the URL (or the example path) in the page source. These are invisible to Lychee when the include sits inside a code fence."
  } >&2
  exit 1
fi
echo "check-broken-includes: no failed github/github-yaml includes in $PUBLIC_DIR" >&2
exit 0
