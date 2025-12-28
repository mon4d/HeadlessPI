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
        printf '\n# Default WIFI_UUID (replace)\nWIFI_UUID="YOUR_WIFI_SSID_OR_UUID"\n' >> "$append_tmp"
        ;;
      WIFI_PASSWORD)
        printf '\n# Default WIFI_PASSWORD (replace)\nWIFI_PASSWORD="YOUR_WIFI_PASSWORD"\n' >> "$append_tmp"
        ;;
      PROJECT_REPO)
        printf '\n# Default PROJECT_REPO (replace)\nPROJECT_REPO="https://github.com/mon4d/example-project.git"\n' >> "$append_tmp"
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

# Default project-repo from internal config, can be overridden here:
PROJECT_REPO="${PROJECT_REPO:-}"
EOF

chmod 0644 "$tmpfile"
mv -f "$tmpfile" "$CONFIG_PATH"
sync

echo "Wrote default config to '$CONFIG_PATH'. Please edit it with real values before booting."

exit 0
