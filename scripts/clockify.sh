#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SKILL_DIR/data/.env"
CONFIG_FILE="$SKILL_DIR/.tmp/clockify-config.json"
PROJECTS_CSV="$SKILL_DIR/.tmp/clockify-projects.csv"
BASE_URL="https://api.clockify.me/api/v1"

# Load API key (safe parsing — no source to avoid arbitrary code execution)
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found. Copy data/.env.example to data/.env and add your API key." >&2
  exit 1
fi
CLOCKIFY_API_KEY=$(grep '^CLOCKIFY_API_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2-)

if [ -z "${CLOCKIFY_API_KEY:-}" ] || [ "$CLOCKIFY_API_KEY" = "your-api-key-here" ]; then
  echo "ERROR: CLOCKIFY_API_KEY is not set. Edit data/.env with your key." >&2
  echo "Get your key from: https://app.clockify.me/user/preferences#advanced" >&2
  exit 1
fi

api() {
  local method="$1"
  local endpoint="$2"
  shift 2
  curl -s -X "$method" "${BASE_URL}${endpoint}" \
    -H "X-Api-Key: $CLOCKIFY_API_KEY" \
    -H "Content-Type: application/json" \
    "$@"
}

load_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config not found. Run 'clockify.sh discover' first." >&2
    exit 1
  fi
  WORKSPACE_ID=$(jq -r '.workspaceId' "$CONFIG_FILE")
  USER_ID=$(jq -r '.userId' "$CONFIG_FILE")
}

cmd_discover() {
  echo "Discovering Clockify user and workspace..." >&2
  USER_JSON=$(api GET /user)
  USER_ID=$(echo "$USER_JSON" | jq -r '.id')
  USER_NAME=$(echo "$USER_JSON" | jq -r '.name')

  WORKSPACES_JSON=$(api GET /workspaces)
  WORKSPACE_ID=$(echo "$WORKSPACES_JSON" | jq -r '.[0].id')
  WORKSPACE_NAME=$(echo "$WORKSPACES_JSON" | jq -r '.[0].name')

  jq -n \
    --arg uid "$USER_ID" \
    --arg uname "$USER_NAME" \
    --arg wid "$WORKSPACE_ID" \
    --arg wname "$WORKSPACE_NAME" \
    '{userId: $uid, userName: $uname, workspaceId: $wid, workspaceName: $wname}' \
    > "$CONFIG_FILE"

  echo "User: $USER_NAME ($USER_ID)" >&2
  echo "Workspace: $WORKSPACE_NAME ($WORKSPACE_ID)" >&2
  echo "$CONFIG_FILE"
}

cmd_last_entry() {
  load_config
  RESPONSE=$(api GET "/workspaces/$WORKSPACE_ID/user/$USER_ID/time-entries?page-size=1&hydrated=false")
  LAST_DATE=$(echo "$RESPONSE" | jq -r '.[0].timeInterval.start[0:10] // empty')
  if [ -z "$LAST_DATE" ]; then
    echo "ERROR: No time entries found in Clockify." >&2
    exit 1
  fi
  echo "$LAST_DATE"
}

cmd_projects() {
  load_config
  echo "Fetching Clockify projects..." >&2

  PAGE=1
  PAGE_SIZE=200
  echo "project_id,project_name" > "$PROJECTS_CSV"

  while true; do
    RESPONSE=$(api GET "/workspaces/$WORKSPACE_ID/projects?page=$PAGE&page-size=$PAGE_SIZE&archived=false")
    COUNT=$(echo "$RESPONSE" | jq 'length')

    if [ "$COUNT" -eq 0 ]; then
      break
    fi

    echo "$RESPONSE" | jq -r '.[] | [.id, .name] | @csv' >> "$PROJECTS_CSV"
    echo "  Page $PAGE: $COUNT projects" >&2

    if [ "$COUNT" -lt "$PAGE_SIZE" ]; then
      break
    fi
    PAGE=$((PAGE + 1))
  done

  TOTAL=$(( $(wc -l < "$PROJECTS_CSV") - 1 ))
  echo "Fetched $TOTAL projects to $PROJECTS_CSV" >&2

  # Merge into project-name-id-map.json (create if missing)
  local PROJECT_MAP="$SKILL_DIR/data/project-name-id-map.json"
  [ -f "$PROJECT_MAP" ] || echo '{}' > "$PROJECT_MAP"

  local CSV_MAP
  CSV_MAP=$(jq -Rs 'split("\n") | .[1:] | map(select(length > 0)) | map(split(",") | {(.[1] | gsub("^\"|\"$"; "")): (.[0] | gsub("^\"|\"$"; ""))}) | add // {}' "$PROJECTS_CSV")

  jq -s '.[0] * .[1]' "$PROJECT_MAP" - <<< "$CSV_MAP" > "${PROJECT_MAP}.tmp" \
    && mv "${PROJECT_MAP}.tmp" "$PROJECT_MAP"

  MAP_TOTAL=$(jq 'length' "$PROJECT_MAP")
  echo "Updated $PROJECT_MAP ($MAP_TOTAL projects)" >&2
  echo "$PROJECTS_CSV"
}

cmd_push() {
  load_config
  local ENTRIES_FILE="${1:-$SKILL_DIR/.tmp/clockify-entries.json}"

  if [ ! -f "$ENTRIES_FILE" ]; then
    echo "ERROR: Entries file not found: $ENTRIES_FILE" >&2
    exit 1
  fi

  local PROJECT_MAP="$SKILL_DIR/data/project-name-id-map.json"
  if [ ! -f "$PROJECT_MAP" ]; then
    echo "ERROR: project-name-id-map.json not found. Run 'clockify.sh projects' first to create it." >&2
    exit 1
  fi

  TOTAL=$(jq 'length' "$ENTRIES_FILE")
  if [ "$TOTAL" -eq 0 ]; then
    echo "No entries to push." >&2
    return 0
  fi
  echo "Pushing $TOTAL entries to Clockify..." >&2

  CREATED=0
  FAILED=0

  for i in $(seq 0 $((TOTAL - 1))); do
    ROW=$(jq ".[$i]" "$ENTRIES_FILE")
    DATE=$(echo "$ROW" | jq -r '.date')
    START_TIME=$(echo "$ROW" | jq -r '.start_time')
    END_TIME=$(echo "$ROW" | jq -r '.end_time')
    PROJECT_NAME=$(echo "$ROW" | jq -r '.project')
    DESCRIPTION=$(echo "$ROW" | jq -r '.description')

    PROJECT_ID=$(jq -r --arg name "$PROJECT_NAME" '.[$name] // empty' "$PROJECT_MAP")
    if [ -z "$PROJECT_ID" ]; then
      echo "ERROR: No project ID found for '$PROJECT_NAME'. Skipping." >&2
      FAILED=$((FAILED + 1))
      continue
    fi

    START_ISO="${DATE}T${START_TIME}:00Z"
    END_ISO="${DATE}T${END_TIME}:00Z"

    BODY=$(jq -n \
      --arg start "$START_ISO" \
      --arg end "$END_ISO" \
      --arg pid "$PROJECT_ID" \
      --arg desc "$DESCRIPTION" \
      '{start: $start, end: $end, projectId: $pid, description: $desc}')

    RESPONSE=$(api POST "/workspaces/$WORKSPACE_ID/time-entries" -d "$BODY")
    ENTRY_ID=$(echo "$RESPONSE" | jq -r '.id // empty')

    if [ -z "$ENTRY_ID" ]; then
      echo "[$((i+1))/$TOTAL] FAILED: $DESCRIPTION ($DATE) — $RESPONSE" >&2
      FAILED=$((FAILED + 1))
    else
      echo "[$((i+1))/$TOTAL] Created: $DESCRIPTION ($DATE)" >&2
      CREATED=$((CREATED + 1))
    fi
    sleep 0.05
  done

  echo "" >&2
  echo "=== DONE: $CREATED created, $FAILED failed out of $TOTAL ===" >&2
}

# Command dispatch
COMMAND="${1:-}"
shift || true

case "$COMMAND" in
  discover)     cmd_discover ;;
  last-entry)   cmd_last_entry ;;
  projects)     cmd_projects ;;
  push)         cmd_push "$@" ;;
  *)
    echo "Usage: clockify.sh {discover|last-entry|projects|push}" >&2
    echo "  discover      — fetch user/workspace IDs" >&2
    echo "  last-entry    — print date of most recent entry" >&2
    echo "  projects      — fetch all projects to CSV" >&2
    echo "  push [file]   — push all entries from JSON file" >&2
    exit 1
    ;;
esac
