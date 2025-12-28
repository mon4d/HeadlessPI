#!/usr/bin/env bash
set -euo pipefail

# redirect stdout/stderr to tty1 if available
if [ -w /dev/tty1 ]; then
  exec > /dev/tty1 2>&1
fi

# startup.sh - Steuerungs-Skript, wird beim Boot ausgeführt
# Derzeit ruft es nur das USB-Mount-Skript auf und prüft den Exit-Status.

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Starting HeadlessPI startup sequence..."

"$SCRIPTDIR/scripts/mount_usb.sh"
ret=$?
if [ $ret -eq 0 ]; then
  echo "USB mounted successfully."
else
  echo "USB mount failed (code: $ret)." >&2
fi

exit $ret
