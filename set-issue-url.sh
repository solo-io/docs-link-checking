#!/usr/bin/env bash
# Write issue URL outputs to GITHUB_OUTPUT.
# Required env vars: ISSUE_NUMBER, REPOSITORY, ISSUE_TITLE, GITHUB_TOKEN
# Optional env vars: LABELS (comma-separated, e.g. "links,bug"), PRODUCT (project Product field value)
set -euo pipefail

if [ -n "${ISSUE_NUMBER:-}" ]; then
  echo "issue_url=https://github.com/${REPOSITORY}/issues/${ISSUE_NUMBER}" >> "$GITHUB_OUTPUT"
  echo "issue_line=Issue: <https://github.com/${REPOSITORY}/issues/${ISSUE_NUMBER}|View issue>" >> "$GITHUB_OUTPUT"

  # Apply labels if provided
  if [ -n "${LABELS:-}" ]; then
    gh issue edit "${ISSUE_NUMBER}" --repo "${REPOSITORY}" --add-label "${LABELS}"
  fi

  # Add to project 24 and set Product field if PRODUCT is set
  if [ -n "${PRODUCT:-}" ]; then
    # GitHub Projects V2 requires the OAuth 'project' scope; use GH_PROJECT_TOKEN if provided
    [ -n "${GH_PROJECT_TOKEN:-}" ] && export GH_TOKEN="$GH_PROJECT_TOKEN"
    PROJECT_ORG="solo-io"
    PROJECT_NUMBER=24

    PROJECT_DATA=$(gh api graphql -F projectNumber=$PROJECT_NUMBER -f org="$PROJECT_ORG" -f query='
      query($projectNumber: Int!, $org: String!) {
        organization(login: $org) {
          projectV2(number: $projectNumber) {
            id
            fields(first: 50) {
              nodes {
                ... on ProjectV2SingleSelectField {
                  id
                  name
                  options { id name }
                }
              }
            }
          }
        }
      }
    ')

    PROJECT_ID=$(echo "$PROJECT_DATA" | jq -r '.data.organization.projectV2.id')
    FIELD_ID=$(echo "$PROJECT_DATA" \
      | jq -r '.data.organization.projectV2.fields.nodes[] | select(.name == "Product") | .id')
    OPTION_ID=$(echo "$PROJECT_DATA" \
      | jq -r --arg p "$PRODUCT" \
          '.data.organization.projectV2.fields.nodes[] | select(.name == "Product") | .options[] | select(.name == $p) | .id')

    ITEM_JSON=$(gh project item-add "$PROJECT_NUMBER" --owner "$PROJECT_ORG" \
      --url "https://github.com/${REPOSITORY}/issues/${ISSUE_NUMBER}" \
      --format json 2>/dev/null || echo '{}')
    ITEM_ID=$(echo "$ITEM_JSON" | jq -r '.id // empty')

    if [ -n "$ITEM_ID" ] && [ -n "$OPTION_ID" ]; then
      gh api graphql -f query='
        mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
          updateProjectV2ItemFieldValue(input: {
            projectId: $projectId
            itemId: $itemId
            fieldId: $fieldId
            value: { singleSelectOptionId: $optionId }
          }) {
            projectV2Item { id }
          }
        }
      ' -f projectId="$PROJECT_ID" -f itemId="$ITEM_ID" -f fieldId="$FIELD_ID" -f optionId="$OPTION_ID"
      echo "Added issue #${ISSUE_NUMBER} to project ${PROJECT_NUMBER} with Product: ${PRODUCT}"
    elif [ -n "$ITEM_ID" ]; then
      echo "Added issue #${ISSUE_NUMBER} to project ${PROJECT_NUMBER} (Product option '${PRODUCT}' not found, field not set)"
    else
      echo "Warning: could not add issue #${ISSUE_NUMBER} to project ${PROJECT_NUMBER}"
    fi
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
