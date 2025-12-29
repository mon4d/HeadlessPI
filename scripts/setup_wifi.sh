wpa_cli -i "$IFACE" set_network "$netid" ssid "\"$SSID\"" >/dev/null 2>&1 || true
#!/usr/bin/env bash
set -euo pipefail

# scripts/setup_wifi.sh
# Use Raspberry Pi's `raspi-config` noninteractive helper to configure Wi-Fi.
# Reads WiFi credentials from a system.config file and delegates to raspi-config.
# Usage: ./scripts/setup_wifi.sh [path/to/system.config]

CONFIG_PATH="${1:-/mnt/usb/system.config}"

get_key() {
  local file="$1" key="$2" line k v
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    if [[ $line =~ ^([A-Za-z0-9_\-]+)=(.*)$ ]]; then
      k="${BASH_REMATCH[1]}"
      v="${BASH_REMATCH[2]}"
      v="$(echo "$v" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      v="${v//$'\r'/}"
      # strip surrounding quotes if present
      while [[ "${v:0:1}" == '"' || "${v:0:1}" == "'" ]]; do v="${v#?}"; done
      while [[ "${v: -1}" == '"' || "${v: -1}" == "'" ]]; do v="${v%?}"; done
      if [ "$k" = "$key" ]; then
        printf '%s' "$v"
        return 0
      fi
    fi
  done < "$file"
  return 1
}

if [ ! -f "$CONFIG_PATH" ]; then
  echo "ERROR: config not found: $CONFIG_PATH"
  exit 1
fi

SSID=""
PSK=""
if ! SSID="$(get_key "$CONFIG_PATH" WIFI_UUID)" || [ -z "$SSID" ]; then
  echo "ERROR: WIFI_UUID not found in config."
  exit 2
fi
if ! PSK="$(get_key "$CONFIG_PATH" WIFI_PASSWORD)" || [ -z "$PSK" ]; then
  echo "ERROR: WIFI_PASSWORD not found in config."
  exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root to call raspi-config."
  exit 3
fi

if ! command -v raspi-config >/dev/null 2>&1; then
  echo "ERROR: raspi-config not found. Install raspi-config or run on Raspberry Pi OS."
  exit 4
fi

# Use raspi-config's non-interactive Wi-Fi helper.
# Defaults: non-hidden (hidden=0) and plain=0 (we add quotes so passphrases with spaces work).
echo "Applying Wi-Fi configuration via raspi-config (SSID='$SSID')"
if sudo raspi-config nonint do_wifi_ssid_passphrase "$SSID" "$PSK" 0 0; then
  echo "Wi-Fi configured via raspi-config. This persists system-wide."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart dhcpcd.service 2>/dev/null || true
  fi
  exit 0
else
  echo "ERROR: raspi-config failed to apply Wi-Fi settings."
  exit 5
fi
