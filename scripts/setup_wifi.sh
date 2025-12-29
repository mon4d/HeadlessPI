#!/usr/bin/env bash
set -euo pipefail

# scripts/setup_wifi.sh
# Read WiFi credentials from a system.config file and apply them to the Pi
# Usage: ./scripts/setup_wifi.sh [path/to/system.config] [wlan-interface]

CONFIG_PATH="${1:-/mnt/usb/system.config}"
IFACE="${2:-wlan0}"

get_key() {
  local file="$1" key="$2" line val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    if [[ $line =~ ^([A-Za-z0-9_\-]+)=(.*)$ ]]; then
      k="${BASH_REMATCH[1]}"
      v="${BASH_REMATCH[2]}"
      v="$(echo "$v" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      v="${v//$'\r'/}"
      # remove any surrounding single or double quotes (handles multiple quotes)
      while [[ "${v:0:1}" == '"' || "${v:0:1}" == "'" ]]; do
        v="${v#?}"
      done
      while [[ "${v: -1}" == '"' || "${v: -1}" == "'" ]]; do
        v="${v%?}"
      done
      if [ "$k" = "$key" ]; then
        printf '%s' "$v"
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

SSID=""
PSK=""
if ! SSID="$(get_key "$CONFIG_PATH" WIFI_UUID)" || [ -z "$SSID" ]; then
  echo "ERROR: WIFI_UUID not found in config." >&2
  exit 2
fi
if ! PSK="$(get_key "$CONFIG_PATH" WIFI_PASSWORD)" || [ -z "$PSK" ]; then
  echo "ERROR: WIFI_PASSWORD not found in config." >&2
  exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root to apply runtime WiFi configuration." >&2
  exit 3
fi

# Escape double quotes and backslashes in SSID and PSK
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/\"/\\\\\"/g'; }
SSID_ESC="$(esc "$SSID")"
PSK_ESC="$(esc "$PSK")"

# Helper: attempt to talk to an existing wpa_supplicant via wpa_cli
try_existing_wpa() {
  if ! command -v wpa_cli >/dev/null 2>&1; then
    return 1
  fi
  # If wpa_cli can report status for the interface, reuse the existing daemon
  if wpa_cli -i "$IFACE" status >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# If an existing wpa_supplicant is managing this interface, just use wpa_cli
if try_existing_wpa; then
  echo "Using existing wpa_supplicant instance for $IFACE"
  netid=$(wpa_cli -i "$IFACE" add_network 2>/dev/null | tr -d '\r' || true)
  if [ -z "$netid" ]; then
    echo "ERROR: failed to create network via wpa_cli" >&2
    exit 5
  fi
  wpa_cli -i "$IFACE" set_network "$netid" ssid "\"$SSID\"" >/dev/null 2>&1 || true
  wpa_cli -i "$IFACE" set_network "$netid" psk "\"$PSK\"" >/dev/null 2>&1 || true
  wpa_cli -i "$IFACE" enable_network "$netid" >/dev/null 2>&1 || true
  wpa_cli -i "$IFACE" select_network "$netid" >/dev/null 2>&1 || true
  echo "Applied runtime WiFi network id $netid (SSID='$SSID') on $IFACE"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart dhcpcd.service 2>/dev/null || true
  fi
  echo "Runtime WiFi configuration applied. Changes are not persisted to disk." 
  exit 0
fi

# No existing controller reachable. Detect stale control socket(s) that could block starting.
ctrl_dirs=("/run/wpa_supplicant" "/var/run/wpa_supplicant")
for d in "${ctrl_dirs[@]}"; do
  sock="$d/$IFACE"
  if [ -e "$sock" ]; then
    # If a wpa_supplicant process is actually running for this iface, prefer it
    if pgrep -f "wpa_supplicant.*-i${IFACE}" >/dev/null 2>&1; then
      echo "wpa_supplicant process already running for $IFACE; try using wpa_cli instead." >&2
      echo "You can run: wpa_cli -i $IFACE status" >&2
      exit 6
    else
      echo "Found stale control socket $sock; removing to allow starting a new wpa_supplicant"
      rm -f "$sock" || true
    fi
  fi
done

# Prepare a private runtime config and private control directory to avoid colliding
# with a system-managed wpa_supplicant instance when possible.
ctrl_dir="/run/wpa_supplicant_${IFACE}"
run_conf="${ctrl_dir}/wpa_supplicant.conf"
mkdir -p "$ctrl_dir"
chmod 750 "$ctrl_dir"

cat > "$run_conf" <<EOF
ctrl_interface=DIR=${ctrl_dir} GROUP=netdev
update_config=1
country=DE

network={
    ssid="${SSID_ESC}"
    psk="${PSK_ESC}"
    key_mgmt=WPA-PSK
}
EOF

chmod 600 "$run_conf"

# Start wpa_supplicant for the iface if not already running for that iface
if ! pgrep -f "wpa_supplicant.*-i${IFACE}" >/dev/null 2>&1; then
  echo "Starting wpa_supplicant for $IFACE using $run_conf"
  wpa_supplicant -B -i "$IFACE" -c "$run_conf" 2>/dev/null || true
  sleep 1
fi

# Now require wpa_cli to be present to program the running daemon
if ! command -v wpa_cli >/dev/null 2>&1; then
  echo "ERROR: wpa_cli not available; cannot apply runtime WiFi config." >&2
  exit 4
fi

# Verify we can talk to the just-started wpa_supplicant
if ! wpa_cli -i "$IFACE" status >/dev/null 2>&1; then
  echo "ERROR: could not communicate with wpa_supplicant on $IFACE" >&2
  echo "Check for existing wpa_supplicant or stale sockets in /run/wpa_supplicant" >&2
  exit 7
fi

netid=$(wpa_cli -i "$IFACE" add_network 2>/dev/null | tr -d '\r' || true)
if [ -z "$netid" ]; then
  echo "ERROR: failed to create network via wpa_cli" >&2
  exit 5
fi

wpa_cli -i "$IFACE" set_network "$netid" ssid "\"$SSID\"" >/dev/null 2>&1 || true
wpa_cli -i "$IFACE" set_network "$netid" psk "\"$PSK\"" >/dev/null 2>&1 || true
wpa_cli -i "$IFACE" enable_network "$netid" >/dev/null 2>&1 || true
wpa_cli -i "$IFACE" select_network "$netid" >/dev/null 2>&1 || true

echo "Applied runtime WiFi network id $netid (SSID='$SSID') on $IFACE"

# Restart DHCP client if systemctl is available
if command -v systemctl >/dev/null 2>&1; then
  systemctl restart dhcpcd.service 2>/dev/null || true
fi

echo "Runtime WiFi configuration applied. Changes are not persisted to disk." 
exit 0
