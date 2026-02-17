#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SKILL_DIR/data/.env"
SKILLS_TARGET="$HOME/.claude/skills"

echo "=== jira-to-clockify installer ==="
echo ""

# --- Step 1: Clockify API key ---
EXISTING_KEY=""
if [ -f "$ENV_FILE" ]; then
  EXISTING_KEY=$(grep '^CLOCKIFY_API_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2-)
fi

if [ -n "$EXISTING_KEY" ] && [ "$EXISTING_KEY" != "your-api-key-here" ]; then
  echo "Clockify API key already configured."
  printf "Replace it? [y/N] "
  read -r REPLACE
  if [[ ! "$REPLACE" =~ ^[Yy]$ ]]; then
    echo "Keeping existing key."
    echo ""
  else
    EXISTING_KEY=""
  fi
fi

if [ -z "$EXISTING_KEY" ] || [ "$EXISTING_KEY" = "your-api-key-here" ]; then
  echo "Get your Clockify API key from:"
  echo "  https://app.clockify.me/user/preferences#advanced"
  echo ""
  printf "Clockify API key: "
  read -r API_KEY

  if [ -z "$API_KEY" ]; then
    echo "ERROR: API key cannot be empty." >&2
    exit 1
  fi

  # Preserve JIRA_AUTHOR if it exists
  JIRA_AUTHOR_LINE=""
  if [ -f "$ENV_FILE" ]; then
    JIRA_AUTHOR_LINE=$(grep '^JIRA_AUTHOR=' "$ENV_FILE" | head -1 || true)
  fi

  echo "CLOCKIFY_API_KEY=$API_KEY" > "$ENV_FILE"
  if [ -n "$JIRA_AUTHOR_LINE" ]; then
    echo "$JIRA_AUTHOR_LINE" >> "$ENV_FILE"
  fi

  echo "Saved to $ENV_FILE"
  echo ""
fi

# --- Step 2: Symlink to ~/.claude/skills/ ---
REAL_SKILL_DIR=$(cd "$SKILL_DIR" && pwd -P)
REAL_SKILLS_TARGET=$(mkdir -p "$SKILLS_TARGET" && cd "$SKILLS_TARGET" && pwd -P)

ALREADY_IN_SKILLS=false
if [[ "$REAL_SKILL_DIR" == "$REAL_SKILLS_TARGET"/* ]]; then
  ALREADY_IN_SKILLS=true
fi

if [ "$ALREADY_IN_SKILLS" = true ]; then
  echo "Skill is already installed at $REAL_SKILL_DIR"
  echo "No symlink needed."
else
  LINK_PATH="$SKILLS_TARGET/jira-to-clockify"

  if [ -L "$LINK_PATH" ]; then
    EXISTING_TARGET=$(readlink "$LINK_PATH")
    if [ "$EXISTING_TARGET" = "$REAL_SKILL_DIR" ]; then
      echo "Symlink already exists: $LINK_PATH -> $REAL_SKILL_DIR"
    else
      echo "Symlink exists but points to: $EXISTING_TARGET"
      printf "Update to point to $REAL_SKILL_DIR? [Y/n] "
      read -r UPDATE
      if [[ "$UPDATE" =~ ^[Nn]$ ]]; then
        echo "Skipped."
      else
        ln -sfn "$REAL_SKILL_DIR" "$LINK_PATH"
        echo "Updated: $LINK_PATH -> $REAL_SKILL_DIR"
      fi
    fi
  elif [ -e "$LINK_PATH" ]; then
    echo "WARNING: $LINK_PATH already exists and is not a symlink. Skipping."
  else
    printf "Create symlink at $LINK_PATH? [Y/n] "
    read -r CREATE
    if [[ "$CREATE" =~ ^[Nn]$ ]]; then
      echo "Skipped."
    else
      mkdir -p "$SKILLS_TARGET"
      ln -sfn "$REAL_SKILL_DIR" "$LINK_PATH"
      echo "Created: $LINK_PATH -> $REAL_SKILL_DIR"
    fi
  fi
fi

echo ""
echo "=== Done ==="
echo "Run the skill with: /jira-to-clockify"
