wpa_cli -i "$IFACE" set_network "$netid" ssid "\"$SSID\"" >/dev/null 2>&1 || true
#!/usr/bin/env bash
set -euo pipefail

# scripts/setup_wifi.sh
# Use Raspberry Pi's `raspi-config` noninteractive helper to configure Wi-Fi.
# Reads WiFi credentials from a system.config file and delegates to raspi-config.
# Supports multiple WiFi networks with auto-fallback and internet connectivity validation.
# Usage: ./scripts/setup_wifi.sh [path/to/system.config] [interface_name]

CONFIG_PATH="${1:-/mnt/usb/system.config}"
IFACE="${2:-wlan0}"
WIFI_WAIT="${WIFI_WAIT:-120}"
WIFI_POLL_INTERVAL=1

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

# Scan for available WiFi networks and return list of SSIDs
scan_available_networks() {
  local iface="$1"
  if ! command -v iwlist >/dev/null 2>&1; then
    echo "WARNING: iwlist not found; cannot scan for networks." >&2
    return 1
  fi
  
  # Scan and extract SSIDs (requires root)
  if sudo iwlist "$iface" scan 2>/dev/null | grep 'ESSID:' | sed 's/.*ESSID:"\(.*\)".*/\1/' | grep -v '^$'; then
    return 0
  else
    echo "WARNING: Network scan failed or returned no results." >&2
    return 1
  fi
}

# Check if a specific SSID is in the list of available networks
is_network_available() {
  local ssid="$1"
  local available_networks="$2"
  echo "$available_networks" | grep -Fxq "$ssid"
}

# Get all WiFi configurations from config file
# Returns format: "1:SSID1:PASSWORD1\n2:SSID2:PASSWORD2\n..."
get_all_wifi_configs() {
  local config_file="$1"
  local configs=""
  local index=1
  
  # First check for legacy WIFI_UUID/WIFI_PASSWORD format
  local legacy_ssid legacy_psk
  if legacy_ssid="$(get_key "$config_file" WIFI_UUID)" && [ -n "$legacy_ssid" ]; then
    if legacy_psk="$(get_key "$config_file" WIFI_PASSWORD)" && [ -n "$legacy_psk" ]; then
      configs="0:${legacy_ssid}:${legacy_psk}"
    fi
  fi
  
  # Now check for numbered format WIFI_SSID_1, WIFI_PASSWORD_1, etc.
  while true; do
    local ssid psk
    if ssid="$(get_key "$config_file" "WIFI_SSID_${index}")" && [ -n "$ssid" ]; then
      if psk="$(get_key "$config_file" "WIFI_PASSWORD_${index}")" && [ -n "$psk" ]; then
        if [ -n "$configs" ]; then
          configs="${configs}\n${index}:${ssid}:${psk}"
        else
          configs="${index}:${ssid}:${psk}"
        fi
      fi
    else
      break
    fi
    index=$((index + 1))
  done
  
  if [ -z "$configs" ]; then
    return 1
  fi
  
  printf '%b\n' "$configs"
  return 0
}

# Wait for interface to get IP and verify internet connectivity
wait_for_connectivity() {
  local iface="$1"
  local timeout="$2"
  local elapsed=0
  
  echo "Waiting for IP address and internet connectivity on $iface (timeout: ${timeout}s)..."
  
  while [ $elapsed -lt $timeout ]; do
    # Check if interface has IP address
    if command -v ip >/dev/null 2>&1 && ip addr show "$iface" 2>/dev/null | grep -q 'inet '; then
      # Try ping test
      if command -v ping >/dev/null 2>&1 && ping -c1 -W1 8.8.8.8 >/dev/null 2>&1; then
        echo "Internet connectivity verified via ping after ${elapsed}s."
        return 0
      fi
      # Try HTTP captive portal test
      if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 3 http://clients3.google.com/generate_204 >/dev/null 2>&1; then
        echo "Internet connectivity verified via HTTP after ${elapsed}s."
        return 0
      fi
    fi
    sleep $WIFI_POLL_INTERVAL
    elapsed=$((elapsed + WIFI_POLL_INTERVAL))
  done
  
  echo "WARNING: No internet connectivity after ${timeout}s." >&2
  return 1
}

# Configure WiFi using raspi-config
configure_wifi_network() {
  local ssid="$1"
  local psk="$2"
  
  if ! command -v raspi-config >/dev/null 2>&1; then
    echo "ERROR: raspi-config not found. Install raspi-config or run on Raspberry Pi OS." >&2
    return 1
  fi
  
  echo "Configuring WiFi network: $ssid"
  if sudo raspi-config nonint do_wifi_ssid_passphrase "$ssid" "$psk" 0 0; then
    echo "WiFi configured successfully via raspi-config."
    if command -v systemctl >/dev/null 2>&1; then
      systemctl restart dhcpcd.service 2>/dev/null || true
    fi
    return 0
  else
    echo "ERROR: raspi-config failed to apply WiFi settings for $ssid." >&2
    return 1
  fi
}

if [ ! -f "$CONFIG_PATH" ]; then
  echo "ERROR: config not found: $CONFIG_PATH"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root to call raspi-config."
  exit 3
fi

# Get all configured WiFi networks
echo "Reading WiFi configurations from $CONFIG_PATH..."
WIFI_CONFIGS=""
if ! WIFI_CONFIGS="$(get_all_wifi_configs "$CONFIG_PATH")"; then
  echo "ERROR: No WiFi configurations found in config."
  echo "Please add either WIFI_UUID/WIFI_PASSWORD or WIFI_SSID_1/WIFI_PASSWORD_1 (and optionally _2, _3, etc.)"
  exit 2
fi

# Count configured networks
NETWORK_COUNT=$(echo "$WIFI_CONFIGS" | wc -l | tr -d ' ')
echo "Found $NETWORK_COUNT configured WiFi network(s)."

# Scan for available networks
echo "Scanning for available WiFi networks on $IFACE..."
AVAILABLE_NETWORKS=""
if AVAILABLE_NETWORKS="$(scan_available_networks "$IFACE")"; then
  AVAILABLE_COUNT=$(echo "$AVAILABLE_NETWORKS" | wc -l | tr -d ' ')
  echo "Found $AVAILABLE_COUNT network(s) in range."
else
  echo "WARNING: Network scan failed. Will attempt all configured networks."
  AVAILABLE_NETWORKS=""
fi

# Try each configured network in order
CONNECTED=0
while IFS= read -r config_line; do
  [ -z "$config_line" ] && continue
  
  # Parse config line: index:ssid:password
  INDEX=$(echo "$config_line" | cut -d':' -f1)
  SSID=$(echo "$config_line" | cut -d':' -f2)
  PSK=$(echo "$config_line" | cut -d':' -f3-)
  
  # Check if network is available (skip scan check if scan failed)
  if [ -n "$AVAILABLE_NETWORKS" ]; then
    if ! is_network_available "$SSID" "$AVAILABLE_NETWORKS"; then
      echo "Skipping '$SSID' (not in range)."
      continue
    fi
  fi
  
  echo "Attempting to connect to: $SSID"
  
  # Configure the network
  if ! configure_wifi_network "$SSID" "$PSK"; then
    echo "Failed to configure $SSID, trying next network..."
    continue
  fi
  
  # Wait for connectivity
  if wait_for_connectivity "$IFACE" "$WIFI_WAIT"; then
    echo "Successfully connected to $SSID with internet access."
    CONNECTED=1
    break
  else
    echo "Network $SSID configured but no internet connectivity. Trying next network..."
  fi
done <<< "$WIFI_CONFIGS"

if [ $CONNECTED -eq 0 ]; then
  echo "ERROR: Failed to connect to any configured WiFi network with internet access."
  exit 5
fi

echo "WiFi setup completed successfully."
exit 0
