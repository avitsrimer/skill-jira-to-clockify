#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SKILL_DIR/data/.env"

ERRORS=0

# Check Clockify API key
echo "Checking Clockify API key..." >&2
if [ ! -f "$ENV_FILE" ]; then
  echo "  FAIL: $ENV_FILE not found." >&2
  echo "  Copy data/.env.example to data/.env and add your API key." >&2
  echo "  Get your key from: https://app.clockify.me/user/preferences#advanced" >&2
  ERRORS=$((ERRORS + 1))
else
  source "$ENV_FILE"
  if [ -z "${CLOCKIFY_API_KEY:-}" ] || [ "$CLOCKIFY_API_KEY" = "your-api-key-here" ]; then
    echo "  FAIL: CLOCKIFY_API_KEY is not set in data/.env" >&2
    ERRORS=$((ERRORS + 1))
  else
    echo "  OK" >&2
  fi
fi

# Check acli Jira auth
echo "Checking Jira auth (acli)..." >&2
if ! command -v acli &>/dev/null; then
  echo "  FAIL: acli not found. Install: brew install atlassian-cli" >&2
  ERRORS=$((ERRORS + 1))
else
  JIRA_AUTH=$(acli jira auth status 2>&1)
  if echo "$JIRA_AUTH" | grep -qi "authenticated"; then
    echo "  OK" >&2
  else
    echo "  FAIL: Jira not authenticated. Run: acli jira auth" >&2
    echo "  $JIRA_AUTH" >&2
    ERRORS=$((ERRORS + 1))
  fi
fi

# Check jq
echo "Checking jq..." >&2
if ! command -v jq &>/dev/null; then
  echo "  FAIL: jq not found. Install: brew install jq" >&2
  ERRORS=$((ERRORS + 1))
else
  echo "  OK" >&2
fi

if [ "$ERRORS" -gt 0 ]; then
  echo "" >&2
  echo "Healthcheck failed with $ERRORS error(s)." >&2
  exit 1
fi

echo "" >&2
echo "All checks passed." >&2
