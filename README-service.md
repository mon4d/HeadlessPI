# Installing HeadlessPI as a systemd service

This repository contains `startup.sh`, which prepares the system and launches the project's `main.py` from the mounted USB drive. To run `startup.sh` automatically at boot (even when nobody is logged in) you can install a systemd service using the provided installer script.

Steps to install on the Raspberry Pi:

1. Copy this repository to the Pi (for example under `/home/pi/HeadlessPI`).
2. On the Pi, run the installer script from within the project directory:

```bash
cd /path/to/HeadlessPI
sudo bash scripts/install_service.sh
```

What the installer does:
- Makes `startup.sh` executable.
- Generates a systemd unit named `headlesspi-startup.service` with `ExecStart` pointing to the absolute path of `startup.sh`.
- Installs the unit to `/etc/systemd/system/` and enables & starts it immediately.

Service behavior:
- Runs as `root` (needed for mounting and system-level actions).
- `Restart=always` with a 5s delay, so if `startup.sh` or the `main.py` process exits, systemd will attempt to restart it.

To inspect or troubleshoot the service:

```bash
sudo systemctl status headlesspi-startup.service
sudo journalctl -u headlesspi-startup.service -f
```

If you need a different install path or user, edit `scripts/install_service.sh` before running it. The installer writes the exact absolute path of `startup.sh` into the unit file so the service runs the right script.
