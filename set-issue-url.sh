#!/usr/bin/env bash
# Write issue URL outputs to GITHUB_OUTPUT.
# Required env vars: ISSUE_NUMBER, REPOSITORY
set -euo pipefail

if [ -n "${ISSUE_NUMBER:-}" ]; then
  echo "issue_url=https://github.com/${REPOSITORY}/issues/${ISSUE_NUMBER}" >> "$GITHUB_OUTPUT"
  echo "issue_line=Issue: <https://github.com/${REPOSITORY}/issues/${ISSUE_NUMBER}|View issue>" >> "$GITHUB_OUTPUT"
else
  echo "issue_url=" >> "$GITHUB_OUTPUT"
  echo "issue_line=" >> "$GITHUB_OUTPUT"
fi
