#!/usr/bin/env bash
set -euo pipefail

status="${1:?usage: manage-recovery-alert.sh <failure|success> <workflow name>}"
workflow_name="${2:?workflow name is required}"
title="[Recovery Alert] ${workflow_name} failed"
run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

issue_number="$(
  gh issue list \
    --repo "$GITHUB_REPOSITORY" \
    --state open \
    --search "\"$title\" in:title" \
    --json number,title \
    --jq ".[] | select(.title == \"$title\") | .number" \
    | head -n 1
)"

if [[ "$status" == "failure" ]]; then
  body="The **${workflow_name}** recovery workflow failed.

- Run: ${run_url}
- Branch: ${GITHUB_REF_NAME}
- Commit: ${GITHUB_SHA}
- Detected: $(date -u +'%Y-%m-%d %H:%M:%S UTC')

Treat this as a recovery incident until the cause is fixed and a replacement run succeeds."
  if [[ -n "$issue_number" ]]; then
    gh issue comment "$issue_number" --repo "$GITHUB_REPOSITORY" --body "$body"
  else
    gh issue create --repo "$GITHUB_REPOSITORY" --title "$title" --body "$body"
  fi
elif [[ "$status" == "success" ]]; then
  if [[ -n "$issue_number" ]]; then
    gh issue comment "$issue_number" --repo "$GITHUB_REPOSITORY" \
      --body "A replacement run succeeded: ${run_url}. Closing this recovery alert."
    gh issue close "$issue_number" --repo "$GITHUB_REPOSITORY" --reason completed
  fi
else
  echo "Unsupported status: $status" >&2
  exit 2
fi
