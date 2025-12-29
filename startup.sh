#!/usr/bin/env bash
set -euo pipefail

# redirect stdout/stderr to tty1 if available
if [ -w /dev/tty1 ]; then
  exec > /dev/tty1 2>&1
fi

# startup.sh - Steuerungs-Skript, wird beim Boot ausgeführt
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$SCRIPTDIR" || exit 1

echo ""
echo " - - - - - - - - - - - - - - - - - - - "
echo "Starting HeadlessPI startup sequence..."

# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# First: Read the internal config file at $SCRIPTDIR/internal.config and write default values to environment variables
USB_LABEL=""
PROJECT_REPO=""
VIRTUAL_ENV=""
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
            USB_LABEL=$val
          fi
          ;;
        PROJECT_REPO)
          if [ -z "${PROJECT_REPO:-}" ]; then
            PROJECT_REPO=$val
          fi
          ;;
        VIRTUAL_ENV)
          if [ -z "${VIRTUAL_ENV:-}" ]; then
            VIRTUAL_ENV=$val
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
echo "Using VIRTUAL_ENV='$VIRTUAL_ENV'"

# If a virtualenv activation script/path was provided in internal.config, expand '~' and try to source it.
if [ -n "${VIRTUAL_ENV:-}" ]; then
  # Strip surrounding single or double quotes if present
  if [ ${#VIRTUAL_ENV} -ge 2 ]; then
    first_char="${VIRTUAL_ENV:0:1}"
    last_char="${VIRTUAL_ENV:$((${#VIRTUAL_ENV}-1)):1}"
    if { [ "$first_char" = '"' ] && [ "$last_char" = '"' ]; } || { [ "$first_char" = "'" ] && [ "$last_char" = "'" ]; }; then
      VIRTUAL_ENV="${VIRTUAL_ENV:1:$((${#VIRTUAL_ENV}-2))}"
    fi
  fi

  # Expand leading ~ to $HOME
  if [[ "$VIRTUAL_ENV" == ~* ]]; then
    VIRTUAL_ENV="${VIRTUAL_ENV/#\~/$HOME}"
  fi

  if [ -f "$VIRTUAL_ENV" ]; then
    echo "Activating virtual environment: $VIRTUAL_ENV"
    # shellcheck disable=SC1090
    source "$VIRTUAL_ENV"
  else
    echo "WARNING: VIRTUAL_ENV '$VIRTUAL_ENV' not found; skipping activation." >&2
  fi
fi

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
IFACE="${WIFI_IFACE:-wlan0}"

if ! bash "$SCRIPTDIR/scripts/setup_wifi.sh" "$CONFIG_PATH" "$IFACE"; then
  sw_ret=$?
  echo "Wifi setup failed (code: $sw_ret). Continuing startup, but network may be unavailable." >&2
  exit $sw_ret
fi

echo "Wifi setup completed; waiting for connectivity..."

# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Wait up to WIFI_WAIT seconds for interface to get IP and for internet connectivity
WIFI_WAIT="${WIFI_WAIT:-60}"
WIFI_POLL_INTERVAL=3
elapsed=0
connected=0

while [ $elapsed -lt $WIFI_WAIT ]; do
if command -v ip >/dev/null 2>&1 && ip addr show "$IFACE" 2>/dev/null | grep -q 'inet '; then
    if command -v ping >/dev/null 2>&1 && ping -c1 -W1 8.8.8.8 >/dev/null 2>&1; then
    connected=1
    break
    fi
    if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 3 http://clients3.google.com/generate_204 >/dev/null 2>&1; then
    connected=1
    break
    fi
fi
sleep $WIFI_POLL_INTERVAL
elapsed=$((elapsed + WIFI_POLL_INTERVAL))
done

if ! [ $connected -eq 1 ]; then
echo "WARNING: WiFi or internet not reachable after ${WIFI_WAIT}s." >&2
fi

echo "WiFi and internet reachable after ${elapsed}s."

# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Clone or update the project repository on the USB drive
USB_PROJECT_DIR="$MOUNT_POINT/system"

if ! bash "$SCRIPTDIR/scripts/update_project_repo.sh" "$CONFIG_PATH" "$USB_PROJECT_DIR"; then
  upr_ret=$?
  echo "Project repository update failed (code: $upr_ret). Continuing startup." >&2
  exit $upr_ret
fi

echo "Project repository is up to date at '$USB_PROJECT_DIR'."

# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Now it's time to install any missing dependencies for the project.
# They are defined in $USB_PROJECT_DIR/requirements-additional.txt
REQ_FILE="$USB_PROJECT_DIR/requirements-additional.txt"
if [ -f "$REQ_FILE" ]; then
  echo "Installing additional dependencies from '$REQ_FILE'..."

  if command -v pip3 >/dev/null 2>&1; then
    echo "Using pip3 from PATH: $(command -v pip3)"
    pip3 install --no-cache-dir -r "$REQ_FILE"
    echo "Additional dependencies installed with pip3."

  elif command -v python3 >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1; then
    echo "pip3 not found in PATH; using 'python3 -m pip' instead."
    python3 -m pip install --no-cache-dir -r "$REQ_FILE"
    echo "Additional dependencies installed with python3 -m pip."

  elif command -v python >/dev/null 2>&1 && python -m pip --version >/dev/null 2>&1; then
    echo "pip3 not found; using 'python -m pip' instead."
    python -m pip install --no-cache-dir -r "$REQ_FILE"
    echo "Additional dependencies installed with python -m pip."

  else
    echo "WARNING: pip3 not found and 'python -m pip' unavailable; cannot install additional dependencies." >&2
  fi
else
  echo "No additional dependencies file found at '$REQ_FILE'. Skipping."
fi

# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# If the raspberry is not in read-only mode, this is when we set it back to read-only
# after all write operations are done and before launching the main script.
# In any future starts the system will boot in read-only mode until we manually trigger the write mode again.
overlay_enabled() {
  # Return 0 if the overlay initramfs method is active (boot=overlay in cmdline or overlay mount on /)
  if grep -q --fixed-strings "boot=overlay" /proc/cmdline 2>/dev/null; then
    return 0
  fi
  if awk '$2=="/" {print $3; exit}' /proc/mounts 2>/dev/null | grep -qw overlay; then
    return 0
  fi
  return 1
}

if !overlay_enabled; then
  echo "Overlay not active; attempting to enable via raspi-config (non-interactive)..."

  if ! command -v raspi-config >/dev/null 2>&1; then
    echo "ERROR: raspi-config not found; cannot enable overlay automatically." >&2
  else
    # Use the distribution-provided raspi-config non-interactive action to enable overlay.
    # According to documentation: sudo raspi-config nonint do_overlayfs 0 -> enable overlay
    echo "Running: sudo raspi-config nonint do_overlayfs 0"
    if sudo raspi-config nonint do_overlayfs 0; then
      echo "raspi-config reported success; syncing and rebooting to apply overlay..."
      sync
      sleep 2
      reboot
    else
      rc=$?
      echo "WARNING: raspi-config failed with exit code $rc. Leaving system writable and continuing." >&2
    fi
  fi
else
  echo "Overlay already active; continuing startup."
fi

# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Finally, launch the main project script main.py
MAIN_SCRIPT="$USB_PROJECT_DIR/main.py"
export CONFIG_DIR="$MOUNT_POINT"
export DATA_DIR="$MOUNT_POINT/data"

if [ -f "$MAIN_SCRIPT" ]; then
  echo "Launching main project script: $MAIN_SCRIPT"
  # Replace shell with the Python process so systemd tracks the correct PID
  exec python3 "$MAIN_SCRIPT"
else
  echo "ERROR: Main project script not found at '$MAIN_SCRIPT'. Cannot continue." >&2
  exit 1
fi


exit 0
