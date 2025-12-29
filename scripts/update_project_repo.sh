#!/usr/bin/env bash
set -euo pipefail

# scripts/update_project_repo.sh
# Clone or update the project repository provided in the config file.
# Usage: ./scripts/update_project_repo.sh /mnt/usb/system.config /mnt/usb/system

CONFIG_PATH="${1:-/mnt/usb/system.config}"
DEST_DIR="${2:-/mnt/usb/system}"

read_project_repo() {
  local file="$1" line key val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    if [[ $line =~ ^([A-Za-z_][A-Za-z0-9_-]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      val="$(echo "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      val="${val//$'\r'/}"
      if [[ $val =~ ^"(.*)"$ ]]; then val="${BASH_REMATCH[1]}"; fi
      if [[ $val =~ ^'(.*)'$ ]]; then val="${BASH_REMATCH[1]}"; fi
      if [ "$key" = "PROJECT_REPO" ]; then
        printf '%s' "$val"
        return 0
      fi
    fi
  done < "$file"
  return 1
}

if [ ! -f "$CONFIG_PATH" ]; then
  echo "ERROR: config not found: $CONFIG_PATH" >&2
  exit 1
fi

PROJECT_REPO=""
if ! PROJECT_REPO="$(read_project_repo "$CONFIG_PATH")" || [ -z "$PROJECT_REPO" ]; then
  echo "ERROR: PROJECT_REPO not set in $CONFIG_PATH" >&2
  exit 2
fi

if ! command -v git >/dev/null 2>&1; then
  echo "ERROR: git is not available on this system" >&2
  exit 3
fi

echo "Updating project repo: $PROJECT_REPO -> $DEST_DIR"

# If dest doesn't exist, clone into it
if [ ! -d "$DEST_DIR" ]; then
  mkdir -p "$(dirname "$DEST_DIR")"
  echo "Cloning $PROJECT_REPO into $DEST_DIR..."
  if git clone --depth 1 "$PROJECT_REPO" "$DEST_DIR"; then
    echo "Clone successful."
    exit 0
  else
    echo "ERROR: git clone failed for $PROJECT_REPO" >&2
    rm -rf "$DEST_DIR" || true
    exit 4
  fi
fi

# If it's a git repo, try to update it
if [ -d "$DEST_DIR/.git" ]; then
  echo "Existing git repo found at $DEST_DIR; attempting to update..."
  set +e
  # fetch and try a fast-forward pull on current branch
  git -C "$DEST_DIR" fetch --all --prune
  cur_branch=$(git -C "$DEST_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [ -n "$cur_branch" ] && git -C "$DEST_DIR" rev-parse --abbrev-ref "origin/$cur_branch" >/dev/null 2>&1; then
    git -C "$DEST_DIR" pull --ff-only origin "$cur_branch"
    pull_res=$?
    if [ $pull_res -ne 0 ]; then
      echo "Fast-forward pull failed; resetting to origin/$cur_branch"
      git -C "$DEST_DIR" reset --hard "origin/$cur_branch"
    fi
  else
    # no upstream info; perform a fetch + reset to origin/HEAD (best effort)
    origin_head=$(git -C "$DEST_DIR" ls-remote --symref origin HEAD | awk '/^ref:/ {print $2; exit}' || true)
    if [ -n "$origin_head" ]; then
      # origin_head looks like refs/heads/main; convert to branch name
      origin_branch="${origin_head#refs/heads/}"
      git -C "$DEST_DIR" reset --hard "origin/$origin_branch"
    else
      echo "Could not determine origin HEAD; skipping automatic reset." >&2
    fi
  fi
  set -e
  echo "Update finished for $DEST_DIR"
  exit 0
fi

# If dest exists but is not a git repo, remove and clone fresh (best effort)
if [ -e "$DEST_DIR" ]; then
  echo "Path exists but is not a git repo. Removing and cloning fresh..."
  rm -rf "$DEST_DIR" || true
  if git clone --depth 1 "$PROJECT_REPO" "$DEST_DIR"; then
    echo "Clone successful."
    exit 0
  else
    echo "ERROR: git clone failed for $PROJECT_REPO" >&2
    rm -rf "$DEST_DIR" || true
    exit 5
  fi
fi

exit 0
