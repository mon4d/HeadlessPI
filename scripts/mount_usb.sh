#!/usr/bin/env bash
set -u

MOUNT_POINT="$1/mnt/usb"
USB_LABEL="${2:-}"

mkdir -p "$MOUNT_POINT"

# If already mounted, return success
if grep -qs " $MOUNT_POINT " /proc/mounts; then
  exit 0
fi

find_device_by_label() {
  if [ -n "$USB_LABEL" ] && [ -e "/dev/disk/by-label/$USB_LABEL" ]; then
    readlink -f "/dev/disk/by-label/$USB_LABEL"
    return 0
  fi
  if [ -d "/dev/disk/by-label" ]; then
    for p in /dev/disk/by-label/*; do
      [ -e "$p" ] || continue
      readlink -f "$p"
      return 0
    done
  fi
  return 1
}

find_device_fallback() {
  for dev in /dev/sd?1 /dev/sd??1; do
    [ -b "$dev" ] || continue
    if ! grep -q "^$dev " /proc/mounts; then
      echo "$dev"
      return 0
    fi
  done
  for dev in /dev/sd?; do
    [ -b "$dev" ] || continue
    if ! grep -q "^$dev " /proc/mounts; then
      echo "$dev"
      return 0
    fi
  done
  return 1
}

device=""
device="$(find_device_by_label 2>/dev/null || true)"
if [ -z "$device" ]; then
  device="$(find_device_fallback 2>/dev/null || true)"
fi

if [ -z "$device" ]; then
  # No device found
  echo "No USB device found"
  exit 2
fi

fstype=""
if command -v blkid >/dev/null 2>&1; then
  fstype=$(blkid -s TYPE -o value "$device" 2>/dev/null || true)
fi

mount_opts=""
case "$fstype" in
  vfat|fat|msdos)
    mount_opts="-o uid=1000,gid=1000,utf8"
    ;;
  ntfs)
    mount_opts="-o uid=1000,gid=1000"
    ;;
  *)
    mount_opts=""
    ;;
esac

# Try mounting; capture any mount error to stderr and return non-zero on failure
if err=$(mount $mount_opts "$device" "$MOUNT_POINT" 2>&1); then
  exit 0
else
  echo "$err"
  exit 3
fi
