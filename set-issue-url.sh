#!/usr/bin/env bash
# Write issue URL outputs to GITHUB_OUTPUT.
# Required env vars: ISSUE_NUMBER, REPOSITORY, ISSUE_TITLE, GITHUB_TOKEN
# Optional env vars: LABELS (comma-separated, e.g. "links,bug")
set -euo pipefail

if [ -n "${ISSUE_NUMBER:-}" ]; then
  echo "issue_url=https://github.com/${REPOSITORY}/issues/${ISSUE_NUMBER}" >> "$GITHUB_OUTPUT"
  echo "issue_line=Issue: <https://github.com/${REPOSITORY}/issues/${ISSUE_NUMBER}|View issue>" >> "$GITHUB_OUTPUT"

  # Apply labels if provided
  if [ -n "${LABELS:-}" ]; then
    gh issue edit "${ISSUE_NUMBER}" --repo "${REPOSITORY}" --add-label "${LABELS}"
  fi

  # Close any older open issues with the same title, excluding the one just created
  OLD_ISSUES=$(gh issue list \
    --repo "${REPOSITORY}" \
    --state open \
    --search "\"${ISSUE_TITLE}\" in:title" \
    --json number \
    --jq ".[].number | select(. != ${ISSUE_NUMBER})")

  for OLD in $OLD_ISSUES; do
    echo "Closing older issue #${OLD}"
    gh issue close "${OLD}" --repo "${REPOSITORY}" --comment "Superseded by #${ISSUE_NUMBER}."
  done
else
  echo "issue_url=" >> "$GITHUB_OUTPUT"
  echo "issue_line=" >> "$GITHUB_OUTPUT"
fi
