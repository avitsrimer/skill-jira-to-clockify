#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT="$SKILL_DIR/.tmp/jira-timesheet.csv"
AUTHOR="${JIRA_AUTHOR:-$(acli jira user view --json 2>/dev/null | jq -r '.displayName // empty')}"
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
echo "$KEYS" | while IFS= read -r key; do
  i=$((i + 1))
  echo "[$i/$COUNT] Fetching $key..." >&2
  acli jira workitem view "$key" --fields '*all' --json 2>/dev/null \
    | jq -r \
      --arg author "$AUTHOR" \
      --arg start "$START_DATE" \
      --arg end "$END_DATE" \
      -f "$SCRIPT_DIR/extract.jq" \
    >> "$OUTPUT"
done

echo "Done. Output saved to $OUTPUT" >&2
