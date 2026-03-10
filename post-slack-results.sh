#!/usr/bin/env bash
# Post link checker results to a Slack channel.
# Required env vars: SLACK_BOT_TOKEN, SLACK_CHANNEL, PRODUCT_NAME,
#                    ERRORS, REDIRECTS, ICON, REPOSITORY, RUN_ID
# Optional env vars: ISSUE_LINE
set -euo pipefail

ISSUE_LINE="${ISSUE_LINE:-}"

PAYLOAD=$(jq -n \
  --arg channel  "${SLACK_CHANNEL}" \
  --arg text     "Link check (${PRODUCT_NAME}): ${ERRORS} errors, ${REDIRECTS} redirects" \
  --arg mrkdwn   "${ICON} <https://github.com/${REPOSITORY}/actions/runs/${RUN_ID}|${PRODUCT_NAME} broken links> | Errors: ${ERRORS} | Redirects: ${REDIRECTS}\n${ISSUE_LINE}" \
  '{
    channel: $channel,
    text: $text,
    blocks: [
      {
        type: "section",
        text: { type: "mrkdwn", text: $mrkdwn }
      }
    ]
  }')

RESP=$(curl -sS \
  -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  -H "Content-Type: application/json; charset=utf-8" \
  -d "${PAYLOAD}")

if echo "${RESP}" | jq -e '.ok == false' > /dev/null; then
  echo "Slack post failed: ${RESP}"
  exit 1
fi
