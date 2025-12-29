#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${1:-/mnt/usb/system.config}"
PROJECT_REPO="${2:-}"

echo "Initializing config at '$CONFIG_PATH' if missing..."

if [ -f "$CONFIG_PATH" ]; then
  echo "Config file already exists at '$CONFIG_PATH'. Checking for missing keys..."

  missing_keys=()
  for key in WIFI_UUID WIFI_PASSWORD PROJECT_REPO; do
    if ! grep -qE "^[[:space:]]*${key}=" "$CONFIG_PATH"; then
      missing_keys+=("$key")
    fi
  done

  if [ ${#missing_keys[@]} -eq 0 ]; then
    echo "All required keys present. Nothing to do."
    exit 0
  fi

  echo "Missing keys: ${missing_keys[*]}. Appending defaults..."
  append_tmp="${CONFIG_PATH}.append.$$"
  : > "$append_tmp"

  for k in "${missing_keys[@]}"; do
    case "$k" in
      WIFI_UUID)
        printf '\nWIFI_UUID="YOUR_WIFI_SSID_OR_UUID"\n' >> "$append_tmp"
        ;;
      WIFI_PASSWORD)
        printf '\nWIFI_PASSWORD="YOUR_WIFI_PASSWORD"\n' >> "$append_tmp"
        ;;
      PROJECT_REPO)
        # Ensure the PROJECT_REPO value is written with a single pair of surrounding
        # double quotes. Strip any existing leading/trailing single or double
        # quotes first, then escape internal double quotes for safe printing.
        repo_val="$PROJECT_REPO"
        # strip leading single/double quotes
        while [[ "${repo_val:0:1}" == '"' || "${repo_val:0:1}" == "'" ]]; do
          repo_val="${repo_val#?}"
        done
        # strip trailing single/double quotes
        while [[ "${repo_val: -1}" == '"' || "${repo_val: -1}" == "'" ]]; do
          repo_val="${repo_val%?}"
        done
        # escape any internal double quotes so printf keeps a single surrounding pair
        repo_esc="${repo_val//\"/\\\"}"
        printf "\n# Default PROJECT_REPO from internal config, can be overridden here:\nPROJECT_REPO=\"%s\"\n" "$repo_esc" >> "$append_tmp"
        ;;
    esac
  done

  cat "$append_tmp" >> "$CONFIG_PATH"
  rm -f "$append_tmp"
  chmod 0644 "$CONFIG_PATH"
  sync

  echo "Appended defaults to '$CONFIG_PATH'. Please edit and fill real values before rebooting."
  exit 0
fi

DEST_DIR="$(dirname "$CONFIG_PATH")"
if [ ! -d "$DEST_DIR" ]; then
  echo "ERROR: mount point directory does not exist: $DEST_DIR" >&2
  exit 1
fi

# Write to a temp file and atomically move into place to avoid partial writes.
tmpfile="${CONFIG_PATH}.tmp.$$"
cat > "$tmpfile" <<EOF
# system.config - HeadlessPI runtime config
# Provide the minimum required values below. Lines starting with '#' are comments.

# Replace with your WiFi credentials here:
WIFI_UUID="YOUR_WIFI_SSID_OR_UUID"
WIFI_PASSWORD="YOUR_WIFI_PASSWORD"

# Default PROJECT_REPO from internal config, can be overridden here:
PROJECT_REPO="${PROJECT_REPO:-}"
EOF

chmod 0644 "$tmpfile"
mv -f "$tmpfile" "$CONFIG_PATH"
sync

echo "Wrote default config to '$CONFIG_PATH'. Please edit it with real values before booting."

exit 0
