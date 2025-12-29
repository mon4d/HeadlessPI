#!/usr/bin/env bash
set -euo pipefail

# install_service.sh
# Generates a systemd service unit for this HeadlessPI repo and installs it.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_NAME="headlesspi-startup.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"

echo "Project directory: $PROJECT_DIR"

if [ ! -f "$PROJECT_DIR/startup.sh" ]; then
  echo "ERROR: startup.sh not found in project directory: $PROJECT_DIR" >&2
  exit 1
fi

echo "Making startup.sh executable..."
if [ $(id -u) -ne 0 ]; then
  sudo chmod +x "$PROJECT_DIR/startup.sh"
else
  chmod +x "$PROJECT_DIR/startup.sh"
fi

echo "Writing systemd unit to $SERVICE_PATH (requires sudo)..."

UNIT_CONTENT="[Unit]
Description=HeadlessPI startup service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStart=/bin/bash '$PROJECT_DIR/startup.sh'
WorkingDirectory=$PROJECT_DIR
StandardOutput=journal
StandardError=journal
SyslogIdentifier=headlesspi-startup
User=root

[Install]
WantedBy=multi-user.target
"

if [ $(id -u) -ne 0 ]; then
  echo "$UNIT_CONTENT" | sudo tee "$SERVICE_PATH" >/dev/null
  sudo chmod 644 "$SERVICE_PATH"
  sudo systemctl daemon-reload
  sudo systemctl enable --now "$SERVICE_NAME"
  echo "Service installed and started. Check status with: sudo systemctl status $SERVICE_NAME"
else
  echo "$UNIT_CONTENT" > "$SERVICE_PATH"
  chmod 644 "$SERVICE_PATH"
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  echo "Service installed and started. Check status with: systemctl status $SERVICE_NAME"
fi

echo "Installation complete."

exit 0
