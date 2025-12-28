#!/usr/bin/env bash
set -euo pipefail

DEST="${CONFIG_PATH:-}"
PROJECT_REPO="${PROJECT_REPO:-}"

echo "Initializing config at '$DEST' if missing..."

if [ -f "$DEST" ]; then
  echo "Config file already exists at '$DEST'. Checking for missing keys..."

  missing_keys=()
  for key in wifi_uuid wifi_password project-repo; do
    if ! grep -qE "^[[:space:]]*${key}=" "$DEST"; then
      missing_keys+=("$key")
    fi
  done

  if [ ${#missing_keys[@]} -eq 0 ]; then
    echo "All required keys present. Nothing to do."
    exit 0
  fi

  echo "Missing keys: ${missing_keys[*]}. Appending defaults..."
  append_tmp="${DEST}.append.$$"
  : > "$append_tmp"

  for k in "${missing_keys[@]}"; do
    case "$k" in
      wifi_uuid)
        printf '\n# Default wifi_uuid (replace)\nwifi_uuid="YOUR_WIFI_SSID_OR_UUID"\n' >> "$append_tmp"
        ;;
      wifi_password)
        printf '\n# Default wifi_password (replace)\nwifi_password="YOUR_WIFI_PASSWORD"\n' >> "$append_tmp"
        ;;
      project-repo)
        printf '\n# Default project-repo (replace)\nproject-repo="https://github.com/mon4d/example-project.git"\n' >> "$append_tmp"
        ;;
    esac
  done

  cat "$append_tmp" >> "$DEST"
  rm -f "$append_tmp"
  chmod 0644 "$DEST"
  sync

  echo "Appended defaults to '$DEST'. Please edit and fill real values before rebooting."
  exit 0
fi

DEST_DIR="$(dirname "$DEST")"
if [ ! -d "$DEST_DIR" ]; then
  echo "ERROR: mount point directory does not exist: $DEST_DIR" >&2
  exit 1
fi

# Write to a temp file and atomically move into place to avoid partial writes.
tmpfile="${DEST}.tmp.$$"
cat > "$tmpfile" <<'EOF'
# system.config - HeadlessPI runtime config
# Provide the minimum required values below. Lines starting with '#' are comments.

# Replace with your WiFi credentials here:
WIFI_UUID="YOUR_WIFI_SSID_OR_UUID"
WIFI_PASSWORD="YOUR_WIFI_PASSWORD"

# Default project repo from internal config, can be overridden here:
PROJECT_REPO="$PROJECT_REPO"

EOF

chmod 0644 "$tmpfile"
mv -f "$tmpfile" "$DEST"
sync

echo "Wrote default config to '$DEST'. Please edit it with real values before booting."

exit 0
