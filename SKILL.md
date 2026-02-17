---
name: jira-to-clockify
description: Sync Jira worklogs to Clockify. Detects where Clockify left off, collects Jira worklogs, maps parents to projects, handles gaps/collisions, and creates time entries.
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
---

# Jira → Clockify Sync

Sync Jira worklogs to Clockify time entries. Fully automated flow with user confirmation at key steps.

## Paths

```
SKILL_DIR=~/.claude/skills/jira-to-clockify
COLLECT=$SKILL_DIR/scripts/collect.sh
CLOCKIFY=$SKILL_DIR/scripts/clockify.sh
TMP=$SKILL_DIR/.tmp
DATA=$SKILL_DIR/data
```

## Step 0: Healthcheck & cleanup

Clean up any leftover temp files from a previous run:
```bash
find $SKILL_DIR/.tmp -type f ! -name '.gitkeep' -delete
```

> **Re-running after failure:** If a previous run failed partway through, simply re-run the skill from the start. This cleanup step ensures a clean slate — no duplicate entries will be created since `.tmp/clockify-entries.json` is wiped before a new run builds it.

Run healthcheck:
```bash
bash $SKILL_DIR/scripts/healthcheck.sh
```

Checks: Clockify API key in `data/.env`, Jira auth via `acli jira auth status`, and `jq` availability.

If any check fails → show the error and stop. The script prints clear fix instructions.

If all pass → run discovery:
```bash
bash $SKILL_DIR/scripts/clockify.sh discover
```

Config saved to `.tmp/clockify-config.json`. Confirm user/workspace to the user.

## Step 1: Find start date from Clockify

Run:
```bash
bash $SKILL_DIR/scripts/clockify.sh last-entry
```

Returns the date of the most recent Clockify time entry.

- **Start date** = day after last entry
- **End date** = last Friday (calculate: `date -v-Fridayw +%Y-%m-%d` or similar)

Present dates to user for confirmation via **AskUserQuestion** before proceeding.

## Step 2: Collect Jira worklogs

Run:
```bash
bash $SKILL_DIR/scripts/collect.sh <start-date> <end-date>
```

Output: `$SKILL_DIR/.tmp/jira-timesheet.csv`

Read the CSV and show the user a summary (ticket count, date range, total hours).

## Step 3: Fetch Clockify projects & update local map

Run:
```bash
bash $SKILL_DIR/scripts/clockify.sh projects
```

Output: `$SKILL_DIR/.tmp/clockify-projects.csv` (columns: `project_id,project_name`)

Then update `data/project-name-id-map.json`:
1. Read the current map from `$DATA/project-name-id-map.json`
2. Read `$TMP/clockify-projects.csv`
3. Merge any new projects (name → UUID) into the map
4. Write back to `$DATA/project-name-id-map.json`

## Step 4: Map Jira parents → Clockify projects

1. Read `$DATA/parent-project-map.json` (Jira parent key → Clockify project name)
2. Read `$DATA/project-name-id-map.json` (Clockify project name → UUID)
3. Extract unique `parent_id + parent_name` pairs from the Jira CSV
4. For any parent NOT in `parent-project-map.json`:
   - List all Clockify project names from `project-name-id-map.json`
   - Suggest the closest match for each unmapped parent
   - **Ask user via AskUserQuestion** — present all unmapped parents at once, each with Clockify project options
5. Save updated `$DATA/parent-project-map.json`

For tickets with no parent, use the ticket key itself as the "parent" for mapping purposes.

## Step 5: Build daily time table

Read the Jira CSV and build a day-by-day breakdown:

### Time conversion
- Jira uses 6h days, Clockify uses 8h days
- Formula: `clockify_seconds = jira_seconds × (8/6)`
- Example: 6h Jira (21600s) → 8h Clockify (28800s)

### Grouping
- Group entries by date
- Each entry: date, project (from parent mapping), description (`TICKET-ID: ticket name`), scaled hours

### Collision check
- If any day exceeds 8h total:
  1. Take the excess
  2. Find the most recent previous workday (Mon-Fri) with < 8h
  3. Move excess there
  4. Repeat until no day exceeds 8h
  5. If all prior days full, warn user

### Gap check
- Identify workdays (Mon-Fri) between start and end date with 0h logged
- For each gap day, note which ticket was logged before and after the gap
- **Ask user via AskUserQuestion** what to log for gap days (suggest the surrounding ticket)

### Present table
Show the final table to the user for approval:

| Date | Project | Description | Hours |
|------|---------|-------------|-------|
| 2024-01-15 | Maintenance | PROJ-1234: Fix login bug | 8.00 |
| ... | ... | ... | ... |

Show daily totals and grand total. Ask user to approve before creating entries.

### Write entries JSON

After user approves the table, write all entries to `$TMP/clockify-entries.json`.

**Format** — array of objects, each entry:
```json
[
  {
    "date": "2025-12-08",
    "start_time": "09:00",
    "end_time": "17:00",
    "project": "Project Alpha",
    "description": "PROJ-1234: Implement feature X",
    "hours": 8.00
  }
]
```

**Rules for start_time/end_time:**
- First entry of the day starts at `09:00`
- Multiple entries on the same day stack sequentially (e.g., 09:00-10:20, 10:20-15:40, 15:40-17:00)
- `hours` field is informational — the actual duration is derived from start/end times

**`project` must match a key in `data/project-name-id-map.json` exactly.** The push script resolves project names to IDs automatically.

## Step 6: Push entries to Clockify

Run:
```bash
bash $SKILL_DIR/scripts/clockify.sh push
```

This reads `$TMP/clockify-entries.json`, resolves project names → IDs via `data/project-name-id-map.json`, and creates all time entries via the Clockify API. Progress is printed to stderr.

## Step 7: Cleanup

Remove all files from `.tmp/` except `.gitkeep`:
```bash
find $SKILL_DIR/.tmp -type f ! -name '.gitkeep' -delete
```

Report summary: total entries created, total hours, date range.
