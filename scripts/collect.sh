#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT="$SKILL_DIR/.tmp/jira-timesheet.csv"
# Resolve JIRA_AUTHOR: env var > .env file > auto-detect from Jira
if [ -z "${JIRA_AUTHOR:-}" ]; then
  ENV_FILE="$SKILL_DIR/data/.env"
  if [ -f "$ENV_FILE" ]; then
    JIRA_AUTHOR=$(grep '^JIRA_AUTHOR=' "$ENV_FILE" | head -1 | cut -d= -f2-)
  fi
fi
if [ -z "${JIRA_AUTHOR:-}" ]; then
  JIRA_AUTHOR=$(acli jira workitem search --jql "assignee = currentUser()" --limit 1 --json 2>/dev/null | jq -r '.[0].fields.assignee.displayName // empty')
fi
AUTHOR="${JIRA_AUTHOR:-}"
if [ -z "$AUTHOR" ]; then
  echo "ERROR: Could not determine Jira author. Set JIRA_AUTHOR env var or check acli auth." >&2
  exit 1
fi

START_DATE="${1:-}"
END_DATE="${2:-}"

if [ -z "$START_DATE" ]; then
  echo "ERROR: Start date is required (YYYY-MM-DD)" >&2
  exit 1
fi

# Default end date: last Friday
if [ -z "$END_DATE" ]; then
  DOW=$(date +%u)
  if [ "$DOW" -ge 5 ]; then
    DAYS_BACK=$((DOW - 5))
  else
    DAYS_BACK=$((DOW + 2))
  fi
  END_DATE=$(date -v-"${DAYS_BACK}"d +%Y-%m-%d)
  echo "End date not specified, using last Friday: $END_DATE" >&2
fi

echo "Collecting tickets from $START_DATE to $END_DATE" >&2

JQL="(worklogAuthor = currentUser() AND worklogDate >= \"$START_DATE\" AND worklogDate <= \"$END_DATE\") OR (assignee = currentUser() AND resolutiondate >= \"$START_DATE\" AND resolutiondate <= \"$END_DATE\")"

echo "Running JQL search..." >&2
KEYS=$(acli jira workitem search --jql "$JQL" --fields 'key' --csv --paginate 2>/dev/null | tail -n +2)

if [ -z "$KEYS" ]; then
  echo "No tickets found for the given range." >&2
  exit 0
fi

COUNT=$(echo "$KEYS" | wc -l | tr -d ' ')
echo "Found $COUNT ticket(s): $(echo "$KEYS" | tr '\n' ' ')" >&2

# Write CSV header
echo "ticket_id,ticket_name,parent_id,parent_name,status,worklog_date,worklog_days,worklog_seconds,resolution_date" > "$OUTPUT"

# Fetch each ticket and extract fields
i=0
TRUNCATED_TICKETS=""
while IFS= read -r key; do
  i=$((i + 1))
  echo "[$i/$COUNT] Fetching $key..." >&2
  TICKET_JSON=$(acli jira workitem view "$key" --fields '*all' --json 2>/dev/null)

  # Detect worklog pagination truncation (Jira returns max 20 worklogs inline)
  WL_TOTAL=$(echo "$TICKET_JSON" | jq '.fields.worklog.total // 0')
  WL_MAX=$(echo "$TICKET_JSON" | jq '.fields.worklog.maxResults // 20')
  if [ "$WL_TOTAL" -gt "$WL_MAX" ]; then
    echo "  WARNING: $key has $WL_TOTAL worklogs but only $WL_MAX returned (Jira pagination limit)" >&2
    TRUNCATED_TICKETS="$TRUNCATED_TICKETS $key"
  fi

  echo "$TICKET_JSON" \
    | jq -r \
      --arg author "$AUTHOR" \
      --arg start "$START_DATE" \
      --arg end "$END_DATE" \
      -f "$SCRIPT_DIR/extract.jq" \
    >> "$OUTPUT"
done <<< "$KEYS"

if [ -n "$TRUNCATED_TICKETS" ]; then
  echo "" >&2
  echo "WARNING: The following tickets had truncated worklogs:$TRUNCATED_TICKETS" >&2
  echo "Some worklogs may be missing. Verify these tickets manually in Jira." >&2
fi

echo "Done. Output saved to $OUTPUT" >&2
