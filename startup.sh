#!/usr/bin/env bash
set -euo pipefail

# redirect stdout/stderr to tty1 if available
if [ -w /dev/tty1 ]; then
  exec > /dev/tty1 2>&1
fi

# startup.sh - Steuerungs-Skript, wird beim Boot ausgeführt
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "\nStarting HeadlessPI startup sequence..."

# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# First: Read the internal config file at $SCRIPTDIR/internal.config and write default values to environment variables
USB_LABEL=""
PROJECT_REPO=""
INTERNAL_CONFIG="$SCRIPTDIR/internal.config"

if [ -f "$INTERNAL_CONFIG" ]; then
  while IFS= read -r _line || [ -n "$_line" ]; do
    line="${_line%%#*}"
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue

    if [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      if [[ $val =~ ^"(.*)"$ ]]; then
        val="${BASH_REMATCH[1]}"
      elif [[ $val =~ ^\'(.*)\'$ ]]; then
        val="${BASH_REMATCH[1]}"
      fi

      case "$key" in
        USB_LABEL)
          if [ -z "${USB_LABEL:-}" ]; then
            USB_LABEL="$val"
          fi
          ;;
        PROJECT_REPO)
          if [ -z "${PROJECT_REPO:-}" ]; then
            PROJECT_REPO="$val"
          fi
          ;;
        *)
          # ignore unknown keys
          ;;
      esac
    fi
  done < "$INTERNAL_CONFIG"
fi

echo "Using USB_LABEL='$USB_LABEL'"
echo "Using PROJECT_REPO='$PROJECT_REPO'"

# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Mount the USB drive
MOUNT_POINT="/mnt/usb"

if ! bash "$SCRIPTDIR/scripts/mount_usb.sh" "$MOUNT_POINT" "$USB_LABEL"; then
    ret=$?
  echo "USB mount failed (code: $ret)." >&2
  exit $ret
fi

echo "USB mounted successfully."

# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Next: Validate config on the mounted USB. Default path is /mnt/usb/system.config
CONFIG_PATH="$MOUNT_POINT/system.config"

if ! bash "$SCRIPTDIR/scripts/check_config.sh" "$CONFIG_PATH"; then
  cfg_ret=$?
  echo "Config validation failed (code: $cfg_ret). Attempting to write defaults to config..." >&2

  # Try to create or append defaults to the config on the USB and re-run validation
  if bash "$SCRIPTDIR/scripts/init_system_config.sh" "$CONFIG_PATH" "$PROJECT_REPO"; then
    echo "Defaults written to '$CONFIG_PATH'. Re-running validation..."
    if ! bash "$SCRIPTDIR/scripts/check_config.sh" "$CONFIG_PATH"; then
      cfg_ret=$?
      echo "Config validation still failed after writing defaults (code: $cfg_ret). Aborting startup." >&2
      exit $cfg_ret
    fi
  else
    init_ret=$?
    echo "Failed to write defaults (code: $init_ret). Aborting startup." >&2
    exit $init_ret
  fi
fi

echo "Config found at '$CONFIG_PATH'. Validation passed."

# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Connect to WiFi using the config values

exit 0
