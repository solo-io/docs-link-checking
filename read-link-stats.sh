#!/usr/bin/env bash
# Read link checker results and write stats to GITHUB_OUTPUT.
# Required env vars: MD_FILE, JSON_FILE
# Optional env vars: OUTPUT_FILE (used to derive a human-readable product name)
set -euo pipefail

ERRORS=""
REDIRECTS=""

# Prefer generated markdown (reports unique errors so Slack matches the issue)
if [ -f "${MD_FILE}" ]; then
  ERRORS=$(grep '| Errors |' "${MD_FILE}" | grep -oE '[0-9]+' | head -1)
  REDIRECTS=$(grep '| Redirects |' "${MD_FILE}" | grep -oE '[0-9]+' | head -1)
fi

if [ -z "${ERRORS}" ] || [ -z "${REDIRECTS}" ]; then
  if [ -f "${JSON_FILE}" ]; then
    ERRORS=$(jq -r '.errors // (.error_map | length) // (.fail_map | length) // 0' "${JSON_FILE}")
    REDIRECTS=$(jq -r '.redirects // (.redirect_map | length) // 0' "${JSON_FILE}")
  fi
fi

if [ "${ERRORS}" = "null" ] || [ -z "${ERRORS}" ]; then ERRORS=0; fi
if [ "${REDIRECTS}" = "null" ] || [ -z "${REDIRECTS}" ]; then REDIRECTS=0; fi

if [ "${ERRORS}" -gt 5 ]; then
  ICON=":red_circle:"
elif [ "${ERRORS}" -le 5 ]; then
  ICON=":large_yellow_circle:"
else
  ICON=":large_green_circle:"
fi

echo "errors=${ERRORS}" >> "$GITHUB_OUTPUT"
echo "redirects=${REDIRECTS}" >> "$GITHUB_OUTPUT"
echo "icon=${ICON}" >> "$GITHUB_OUTPUT"

# Derive a human-readable product name from OUTPUT_FILE if provided
if [ -n "${OUTPUT_FILE:-}" ]; then
  NAME="${OUTPUT_FILE}"
  NAME="${NAME%-links}"
  NAME=$(echo "${NAME}" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')
  echo "product_name=${NAME:-Link Check}" >> "$GITHUB_OUTPUT"
fi
