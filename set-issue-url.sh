#!/usr/bin/env bash
# Write issue URL outputs to GITHUB_OUTPUT.
# Required env vars: ISSUE_NUMBER, REPOSITORY, ISSUE_TITLE, GITHUB_TOKEN
# Optional env vars: LABELS (comma-separated, e.g. "links,bug"), PRODUCT (project Product field value)
set -euo pipefail

if [ -n "${ISSUE_NUMBER:-}" ]; then
  ISSUE_URL="https://github.com/${REPOSITORY}/issues/${ISSUE_NUMBER}"
  echo "issue_url=${ISSUE_URL}" >> "$GITHUB_OUTPUT"

  # Appended to the Slack line when the project update fails, so a silent
  # board failure is visible where the results are actually read.
  PROJECT_NOTE=""

  # Apply labels if provided. Retry up to 3 times to handle GitHub GraphQL
  # eventual-consistency lag after issue creation via the REST API.
  if [ -n "${LABELS:-}" ]; then
    for attempt in 1 2 3; do
      if gh issue edit "${ISSUE_NUMBER}" --repo "${REPOSITORY}" --add-label "${LABELS}"; then
        break
      fi
      if [ "$attempt" -lt 3 ]; then
        echo "Label application failed (attempt ${attempt}/3); retrying in 5s..."
        sleep 5
      else
        echo "Warning: could not add labels to issue #${ISSUE_NUMBER} after 3 attempts."
      fi
    done
  fi

  # Close any older open issues with the same title, excluding the one just created.
  # Done before the project update so a project/token failure can't leave stale issues open.
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

  # Add to project 24 and set Product field if PRODUCT is set.
  # Wrapped with `set +e` so a missing/under-scoped project token cannot abort the step.
  if [ -n "${PRODUCT:-}" ]; then
    if [ -z "${GH_PROJECT_TOKEN:-}" ]; then
      echo "::error::GH_PROJECT_TOKEN is empty, so issue #${ISSUE_NUMBER} was not added to the board and has no Product set. The token needs the 'project' scope."
      PROJECT_NOTE=" · :warning: not added to the board"
    else
      # GitHub Projects V2 requires the OAuth 'project' scope; use GH_PROJECT_TOKEN if provided
      export GH_TOKEN="$GH_PROJECT_TOKEN"
      PROJECT_ORG="solo-io"
      PROJECT_NUMBER=24

      set +e
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

      PROJECT_ID=$(echo "$PROJECT_DATA" | jq -r '.data.organization.projectV2.id // empty')
      FIELD_ID=$(echo "$PROJECT_DATA" \
        | jq -r '[.data.organization.projectV2.fields.nodes[]? | select(.name == "Product")][0].id // empty')
      OPTION_ID=$(echo "$PROJECT_DATA" \
        | jq -r --arg p "$PRODUCT" \
            '[.data.organization.projectV2.fields.nodes[]? | select(.name == "Product") | .options[]? | select(.name == $p)][0].id // empty')

      # Add the issue by node ID.
      #
      # Deliberately NOT `gh project item-add --owner`: that subcommand first
      # resolves the owner login to a user or an organization, and that lookup
      # started returning "unknown owner type" on 2026-08-25 while every other
      # project call with the same token kept working. The failure was silent,
      # so eight weekly reports landed on the board with no Product set and the
      # runs still reported success. Calling the mutation directly skips owner
      # resolution. It is also idempotent: an issue already on the board
      # returns its existing item ID.
      ISSUE_NODE_ID=$(gh api graphql -F number="$ISSUE_NUMBER" \
        -f owner="${REPOSITORY%%/*}" -f repo="${REPOSITORY##*/}" -f query='
        query($owner: String!, $repo: String!, $number: Int!) {
          repository(owner: $owner, name: $repo) {
            issue(number: $number) { id }
          }
        }
      ' | jq -r '.data.repository.issue.id // empty')

      ITEM_ID=""
      if [ -n "$ISSUE_NODE_ID" ] && [ -n "$PROJECT_ID" ]; then
        ITEM_ID=$(gh api graphql -f projectId="$PROJECT_ID" -f contentId="$ISSUE_NODE_ID" -f query='
          mutation($projectId: ID!, $contentId: ID!) {
            addProjectV2ItemById(input: { projectId: $projectId, contentId: $contentId }) {
              item { id }
            }
          }
        ' | jq -r '.data.addProjectV2ItemById.item.id // empty')
      fi

      if [ -n "$ITEM_ID" ] && [ -n "$PROJECT_ID" ] && [ -n "$FIELD_ID" ] && [ -n "$OPTION_ID" ]; then
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
        if [ $? -eq 0 ]; then
          echo "Added issue #${ISSUE_NUMBER} to project ${PROJECT_NUMBER} with Product: ${PRODUCT}"
        else
          echo "::error::Added issue #${ISSUE_NUMBER} to project ${PROJECT_NUMBER}, but setting Product=${PRODUCT} failed."
          PROJECT_NOTE=" · :warning: Product not set"
        fi
      elif [ -n "$ITEM_ID" ]; then
        echo "::error::Added issue #${ISSUE_NUMBER} to project ${PROJECT_NUMBER}, but Product option '${PRODUCT}' was not found in the project's Product field. The field is unset."
        PROJECT_NOTE=" · :warning: Product not set"
      else
        echo "::error::Could not add issue #${ISSUE_NUMBER} to project ${PROJECT_NUMBER}. Check that DOCS_TOKEN still has project access."
        PROJECT_NOTE=" · :warning: not added to the board"
      fi
      set -e
    fi
  fi

  echo "issue_line=Issue: <${ISSUE_URL}|View issue>${PROJECT_NOTE}" >> "$GITHUB_OUTPUT"
else
  echo "issue_url=" >> "$GITHUB_OUTPUT"
  echo "issue_line=" >> "$GITHUB_OUTPUT"
fi
