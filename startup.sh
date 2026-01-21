#!/usr/bin/env bash
set -euo pipefail

# redirect stdout/stderr to tty1 if available
if [ -w /dev/tty1 ]; then
  exec > /dev/tty1 2>&1
fi

VERSION="0.5.0"

_shutdown_bin() {
  if command -v shutdown >/dev/null 2>&1; then
    command -v shutdown
    return 0
  fi
  if [ -x /sbin/shutdown ]; then
    echo "/sbin/shutdown"
    return 0
  fi
  if [ -x /usr/sbin/shutdown ]; then
    echo "/usr/sbin/shutdown"
    return 0
  fi
  return 1
}

time_is_synchronized() {
  if command -v timedatectl >/dev/null 2>&1; then
    local synced
    synced="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    if [ "$synced" = "yes" ]; then
      return 0
    fi
  fi

  if [ -f /run/systemd/timesync/synchronized ]; then
    return 0
  fi

  return 1
}

wait_for_time_sync() {
  local timeout_s=300
  local poll_s=5
  local waited=0

  while [ $waited -lt $timeout_s ]; do
    if time_is_synchronized; then
      return 0
    fi
    sleep $poll_s
    waited=$((waited + poll_s))
  done

  # Fallback after timeout: if year >= 2025, assume time is plausible
  local year
  year="$(date +%Y)"
  if [ "$year" -ge 2025 ]; then
    echo "Time sync not confirmed, but year=$year looks plausible; proceeding."
    return 0
  fi

  return 1
}

schedule_daily_reboot_4am() {
  local shutdown_cmd
  if ! shutdown_cmd="$(_shutdown_bin)"; then
    echo "WARNING: shutdown command not found; cannot schedule daily reboot."
    return 0
  fi

  echo "Scheduling daily reboot at 04:00 (local time)..."
  "$shutdown_cmd" -c >/dev/null 2>&1 || true
  "$shutdown_cmd" -r 04:00 "HeadlessPI: System will automatically reboot at 04:00" >/dev/null 2>&1 || true
}

# startup.sh - Steuerungs-Skript, wird beim Boot ausgeführt
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$SCRIPTDIR" || exit 1

echo ""
echo " - - - - - - - - - - - - - - - - - - - "
echo "Starting HeadlessPI startup sequence..."
echo "Version: $VERSION"

# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# First: Read the internal config file at $SCRIPTDIR/internal.config and write default values to environment variables
STARTUP_REPO=""
USB_LABEL=""
PROJECT_REPO=""
VIRTUAL_ENV=""
INTERNAL_CONFIG="$SCRIPTDIR/internal.config"

# Helper: remove matching surrounding single or double quotes from a string
strip_surrounding_quotes() {
  local s="$1"
  while [ ${#s} -ge 2 ]; do
    local first="${s:0:1}"
    local last="${s:$((${#s}-1)):1}"
    if { [ "$first" = '"' ] && [ "$last" = '"' ]; } || { [ "$first" = "'" ] && [ "$last" = "'" ]; }; then
      s="${s:1:$((${#s}-2))}"
    else
      break
    fi
  done
  printf '%s' "$s"
}

if [ -f "$INTERNAL_CONFIG" ]; then
  while IFS= read -r _line || [ -n "$_line" ]; do
    line="${_line%%#*}"
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue

    if [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      # Strip any surrounding single/double quotes so values are clean for later use
      val="$(strip_surrounding_quotes "$val")"

        case "$key" in
          STARTUP_REPO)
            if [ -z "${STARTUP_REPO:-}" ]; then
              STARTUP_REPO=$val
            fi
            ;;
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

echo "Using STARTUP_REPO='$STARTUP_REPO'"
echo "Using USB_LABEL='$USB_LABEL'"
echo "Using PROJECT_REPO='$PROJECT_REPO'"
echo "Using VIRTUAL_ENV='$VIRTUAL_ENV'"


# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# If a virtualenv activation script/path was provided in internal.config, expand '~' and try to source it.
if [ -n "${VIRTUAL_ENV:-}" ]; then
  # Expand leading ~ to $HOME
  if [[ "$VIRTUAL_ENV" == ~* ]]; then
    VIRTUAL_ENV="${VIRTUAL_ENV/#\~/$HOME}"
  fi

  if [ -f "$VIRTUAL_ENV" ]; then
    echo "Activating virtual environment: $VIRTUAL_ENV"
    # shellcheck disable=SC1090
    source "$VIRTUAL_ENV"
  else
    echo "WARNING: VIRTUAL_ENV '$VIRTUAL_ENV' not found; skipping activation."
  fi
fi


# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Mount the USB drive
MOUNT_POINT="/mnt/usb"

if ! bash "$SCRIPTDIR/scripts/mount_usb.sh" "$MOUNT_POINT" "$USB_LABEL"; then
  ret=$?
  echo "USB mount failed (code: $ret)."
  exit $ret
fi

echo "USB mounted successfully."


# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Next: Validate config on the mounted USB. Default path is /mnt/usb/system.config
CONFIG_PATH="$MOUNT_POINT/system.config"

if ! bash "$SCRIPTDIR/scripts/check_config.sh" "$CONFIG_PATH"; then
  cfg_ret=$?
  echo "Config validation failed (code: $cfg_ret). Attempting to write defaults to config..."

  # Try to create or append defaults to the config on the USB and re-run validation
  if bash "$SCRIPTDIR/scripts/init_system_config.sh" "$CONFIG_PATH" "$PROJECT_REPO"; then
    echo "Defaults written to '$CONFIG_PATH'. Re-running validation..."
    if ! bash "$SCRIPTDIR/scripts/check_config.sh" "$CONFIG_PATH"; then
      cfg_ret=$?
      echo "Config validation still failed after writing defaults (code: $cfg_ret). Aborting startup."
      exit $cfg_ret
    fi
  else
    init_ret=$?
    echo "Failed to write defaults (code: $init_ret). Aborting startup."
    exit $init_ret
  fi
fi

echo "Config found at '$CONFIG_PATH'. Validation passed."


# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Check if system logging is enabled in the config and set up log file if needed
SYSTEM_LOGGING=""
if [ -f "$CONFIG_PATH" ]; then
  while IFS= read -r _line || [ -n "$_line" ]; do
    line="${_line%%#*}"
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue

    if [[ $line =~ ^([A-Za-z_][A-Za-z0-9_-]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      val="$(strip_surrounding_quotes "$val")"

      if [ "$key" = "SYSTEM_LOGGING" ]; then
        SYSTEM_LOGGING="$val"
        break
      fi
    fi
  done < "$CONFIG_PATH"
fi

# Enable logging if SYSTEM_LOGGING=TRUE (case-insensitive)
if [[ "${SYSTEM_LOGGING^^}" == "TRUE" ]]; then
  TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
  LOG_FILE="$MOUNT_POINT/startup_${TIMESTAMP}.log"
  
  echo "System logging enabled. Logging to: $LOG_FILE"
  
  # Clean up old log files (older than 2 days)
  find "$MOUNT_POINT" -maxdepth 1 -name "startup_*.log" -type f -mtime +2 -delete 2>/dev/null || true
  
  # Redirect all subsequent output to both console and log file
  exec > >(tee -a "$LOG_FILE") 2>&1
  
  echo "==================================="
  echo "HeadlessPI Startup Log"
  echo "Started: $(date)"
  echo "Version: $(VERSION)"
  echo "==================================="
fi


# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Connect to WiFi using the config values
# setup_wifi.sh now handles both configuration and connectivity verification
IFACE="${WIFI_IFACE:-wlan0}"

if ! bash "$SCRIPTDIR/scripts/setup_wifi.sh" "$CONFIG_PATH" "$IFACE"; then
  sw_ret=$?
  echo "WiFi setup failed (code: $sw_ret). Network unavailable."
  exit $sw_ret
fi

echo "WiFi setup completed with internet connectivity verified."

# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# With internet connectivity, wait briefly for time synchronization before scheduling a reboot at 04:00.
# If time isn't synchronized after 5m / 300s reboot the system to try again.
echo "Waiting for time synchronization (up to 5m / 300s) before scheduling 04:00 reboot..."
if wait_for_time_sync; then
  echo "Time synchronized; setting 04:00 reboot schedule."
  schedule_daily_reboot_4am
else
  echo "WARNING: Time not synchronized after 5 minutes; Rebooting to try again."
  reboot
  sleep 60
fi

# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# If the filesystem is read-write, we can try to update the startup scripts from the STARTUP_REPO.
if [ -n "$STARTUP_REPO" ]; then
  if grep -qw "ro," /proc/mounts 2>/dev/null | awk '$2=="/" {print $3; exit}'; then
    echo "Filesystem is read-only; checking if there are any updates available."
    git config --global --add safe.directory "$SCRIPTDIR"
    if git -C "$SCRIPTDIR" fetch --all --tags --prune && git -C "$SCRIPTDIR" remote show origin | grep -q 'local out of date'; then
      echo "Updates are available in '$STARTUP_REPO'"
      echo "Making filesystem writable and rebooting to apply updates..."
      if command -v raspi-config >/dev/null 2>&1; then
        # Use the distribution-provided raspi-config non-interactive action to disable overlay.
        # According to documentation: sudo raspi-config nonint do_overlayfs 1 -> disable overlay
        echo "Running: sudo raspi-config nonint do_overlayfs 1" # in the raspberry config 0 is to enable overlay, 1 to disable
        if sudo raspi-config nonint do_overlayfs 1; then
          echo "raspi-config reported success; syncing and rebooting to apply updates..."
          sync
          sleep 2
          reboot
          sleep 60
        else
          rc=$?
          echo "ERROR: raspi-config failed with exit code $rc. Cannot apply updates automatically."
        fi
      else
        echo "ERROR: raspi-config not found; cannot enable write mode automatically."
      fi
    else
      echo "No updates available for startup scripts."
    fi
  else
    echo "Updating startup scripts from repository: $STARTUP_REPO"
    git config --global --add safe.directory "$SCRIPTDIR"
    if git -C "$SCRIPTDIR" fetch --all --tags --prune && git -C "$SCRIPTDIR" reset --hard origin/main; then
      echo "Startup scripts updated successfully."
    else
      echo "WARNING: Failed to update startup scripts from '$STARTUP_REPO'. Continuing with existing scripts."
    fi
  fi
else
  echo "No STARTUP_REPO defined; skipping startup script update."
fi


# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Clone or update the project repository on the USB drive
USB_PROJECT_DIR="$MOUNT_POINT/system"

if ! bash "$SCRIPTDIR/scripts/update_project_repo.sh" "$CONFIG_PATH" "$USB_PROJECT_DIR"; then
  upr_ret=$?
  echo "Project repository update failed (code: $upr_ret). Continuing startup."
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
    echo "WARNING: pip3 not found and 'python -m pip' unavailable; cannot install additional dependencies."
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
    echo "found overlayfs indication: boot=overlay in /proc/cmdline"
    return 0
  fi
  if awk '$2=="/" {print $3; exit}' /proc/mounts 2>/dev/null | grep -qw overlay; then
    echo "found overlayfs indication: overlay mount on /"
    return 0
  fi
  echo "found no overlayfs indication"
  return 1
}

if ! overlay_enabled; then
  echo "Overlay not active; attempting to enable via raspi-config (non-interactive)..."

  if ! command -v raspi-config >/dev/null 2>&1; then
    echo "ERROR: raspi-config not found; cannot enable overlay automatically."
  else
    # Use the distribution-provided raspi-config non-interactive action to enable overlay.
    # According to documentation: sudo raspi-config nonint do_overlayfs 0 -> enable overlay
    echo "Running: sudo raspi-config nonint do_overlayfs 0" # in the raspberry config 0 is to enable overlay, 1 to disable
    if sudo raspi-config nonint do_overlayfs 0; then
      echo "raspi-config reported success; syncing and rebooting to apply overlay..."
      sync
      sleep 2
      reboot
      sleep 60
    else
      rc=$?
      echo "WARNING: raspi-config failed with exit code $rc. Leaving system writable and continuing."
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
  echo "ERROR: Main project script not found at '$MAIN_SCRIPT'. Cannot continue."
  exit 1
fi


exit 0
