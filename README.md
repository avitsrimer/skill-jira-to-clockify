# jira-to-clockify

A Claude Code skill that syncs Jira worklogs to Clockify time entries. Detects where Clockify left off, collects Jira worklogs, maps Jira parent tickets to Clockify projects, handles time gaps and collisions, and creates time entries via the Clockify REST API.

## Usage

```
/jira-to-clockify
```

Claude handles the orchestration: collecting data, asking questions, building the time table, and writing a JSON file. A shell script handles the Clockify API calls.

## Dependencies

| Tool | Purpose | Install |
|------|---------|---------|
| [acli](https://developer.atlassian.com/cloud/acli/) | Jira worklog queries | `brew install atlassian-cli` or see Atlassian docs |
| [jq](https://jqlang.github.io/jq/) | JSON processing | `brew install jq` |
| [curl](https://curl.se/) | HTTP requests to Clockify API | Pre-installed on macOS |
| bash | Shell scripts | Pre-installed on macOS |

### Jira auth

Uses your existing `acli` session. Authenticate once with:

```bash
acli auth
```

### Clockify API key

1. Go to https://app.clockify.me/user/preferences#advanced
2. Copy your API key
3. Create `data/.env` from the template:

```bash
cp data/.env.example data/.env
# Edit data/.env and paste your key
```

## How it works

1. **Discover** Clockify workspace and user via API
2. **Detect start date** from the most recent Clockify time entry
3. **Collect Jira worklogs** via `acli` JQL search for the date range
4. **Fetch Clockify projects** and update the local name-to-ID map
5. **Map Jira parents to Clockify projects** (asks user for unmapped parents)
6. **Build daily time table** with:
   - Time scaling: 6h Jira day -> 8h Clockify day (`seconds * 8/6`)
   - Collision spreading: days over 8h overflow to previous workdays
   - Gap detection: flags workdays with 0h logged, asks user what to fill
7. **Write entries JSON** to `.tmp/clockify-entries.json` after user approval
8. **Push to Clockify** via `clockify.sh push` (reads JSON, resolves project IDs, creates entries)
9. **Cleanup** temporary files

## Directory structure

```
.
├── SKILL.md                          # Skill definition (orchestration instructions for Claude)
├── .gitignore
├── scripts/
│   ├── collect.sh                    # Jira worklog collector via acli
│   ├── extract.jq                    # jq filter for Jira ticket JSON
│   └── clockify.sh                   # Clockify API wrapper
├── data/
│   ├── .env.example                  # Template: CLOCKIFY_API_KEY=your-key-here
│   ├── .env                          # Actual API key (gitignored)
│   ├── parent-project-map.json       # Persistent: Jira parent key -> Clockify project name
│   └── project-name-id-map.json      # Persistent: Clockify project name -> project UUID
└── .tmp/                             # Ephemeral working files (gitignored)
```

## Scripts

### `clockify.sh`

```bash
clockify.sh discover       # Fetch user/workspace IDs -> .tmp/clockify-config.json
clockify.sh last-entry     # Print date of most recent time entry
clockify.sh projects       # Fetch all projects -> .tmp/clockify-projects.csv
clockify.sh create-entry <start-iso> <end-iso> <project-id> <description>
clockify.sh push [file]    # Push all entries from JSON file (default: .tmp/clockify-entries.json)
```

### `collect.sh`

```bash
collect.sh <start-date> [end-date]   # Collect Jira worklogs -> .tmp/jira-timesheet.csv
```

End date defaults to last Friday if omitted.

## Data files

### `parent-project-map.json`

Maps Jira parent ticket keys to Clockify project names. Persists across runs so you only need to map each parent once.

```json
{
  "PROJ-100": "Maintenance",
  "PROJ-200": "New Feature Alpha"
}
```

### `project-name-id-map.json`

Maps Clockify project names to their UUIDs. Auto-populated by `clockify.sh projects`.

```json
{
  "Maintenance": "64c777ddd3fcab07cfbb210c",
  "Holidays": "63a45864f8a86d473b3e685e"
}
```

### `.tmp/clockify-entries.json`

The intermediate file Claude writes after user approval. Consumed by `clockify.sh push`.

```json
[
  {
    "date": "2025-12-08",
    "start_time": "09:00",
    "end_time": "17:00",
    "project": "Maintenance",
    "description": "PROJ-1234: Implement feature X",
    "hours": 8.00
  }
]
```

## Time conversion

Jira tracks time in 6-hour days; Clockify uses 8-hour days.

| Jira | Clockify |
|------|----------|
| 1d (6h / 21600s) | 8h (28800s) |
| 0.5d (3h / 10800s) | 4h (14400s) |

Formula: `clockify_seconds = jira_seconds * 8 / 6`
