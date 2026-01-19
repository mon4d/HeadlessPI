#!/usr/bin/env bash
set -euo pipefail

# scripts/check_config.sh
# Validate a simple key=value config file at /mnt/usb/system.config
# Usage: ./scripts/check_config.sh [path/to/system.config]

CONFIG_PATH="${1:-/mnt/usb/system.config}"

echo "Checking config at '$CONFIG_PATH'..."

if [ ! -f "$CONFIG_PATH" ]; then
  echo "ERROR: Config file not found: $CONFIG_PATH"
  exit 1
fi

WIFI_UUID=""
WIFI_PASSWORD=""
PROJECT_REPO=""

while IFS= read -r _line || [ -n "$_line" ]; do
  line="${_line%%#*}"           # strip comments starting with #
  # trim leading and trailing whitespace
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -z "${line}" ] && continue

    if [[ $line =~ ^([A-Za-z_][A-Za-z0-9_-]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      # trim whitespace around the value
      val="$(echo "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      # remove DOS CR if present
      val="${val//$'\r'/}"
      # remove any surrounding single or double quotes (handles multiple quotes)
      while [[ "${val:0:1}" == '"' || "${val:0:1}" == "'" ]]; do
        val="${val#?}"
      done
      while [[ "${val: -1}" == '"' || "${val: -1}" == "'" ]]; do
        val="${val%?}"
      done

      case "$key" in
        WIFI_UUID) #upgrade this to use SSID terminology instead
          WIFI_UUID=$val
          ;;
        WIFI_PASSWORD)
          WIFI_PASSWORD=$val
          ;;
        PROJECT_REPO)
          PROJECT_REPO=$val
          ;;
        *)
          # ignore unknown keys
          ;;
      esac
    fi
done < "$CONFIG_PATH"

missing=()
[ -z "$WIFI_UUID" ] && missing+=("WIFI_UUID")
[ -z "$WIFI_PASSWORD" ] && missing+=("WIFI_PASSWORD")
[ -z "$PROJECT_REPO" ] && missing+=("PROJECT_REPO")

if [ ${#missing[@]} -ne 0 ]; then
  echo "ERROR: Missing required keys in config: ${missing[*]}"
  exit 2
fi

# validate using grep -E for portability and clarity
if printf '%s' "$PROJECT_REPO" | grep -E -q '^(https://|git@|ssh://|git://)'; then
  repo_ok=0
else
  repo_ok=1
fi

if [ $repo_ok -ne 0 ]; then
  echo "WARNING: 'PROJECT_REPO' does not look like a valid URL/git repository: $PROJECT_REPO"
fi

# Optional: warn if password is short
if [ ${#WIFI_PASSWORD} -lt 8 ]; then
  echo "WARNING: WIFI_PASSWORD seems short (<8 chars)."
fi

echo "Config OK. Summary:"
echo "  WIFI_UUID=[$WIFI_UUID]"
echo "  PROJECT_REPO=[$PROJECT_REPO]"

exit 0
