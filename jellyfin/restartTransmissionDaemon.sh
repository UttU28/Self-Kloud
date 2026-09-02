#!/usr/bin/env bash
# Restart host transmission-daemon (used by Apeksha Docker for proxy switch).
set -euo pipefail

dbus_addr="${DBUS_SYSTEM_BUS_ADDRESS:-unix:path=/var/run/dbus/system_bus_socket}"

if [ -S /var/run/dbus/system_bus_socket ] || [ -n "${DBUS_SYSTEM_BUS_ADDRESS:-}" ]; then
  if DBUS_SYSTEM_BUS_ADDRESS="$dbus_addr" dbus-send --system --print-reply \
    --dest=org.freedesktop.systemd1 \
    /org/freedesktop/systemd1 \
    org.freedesktop.systemd1.Manager.RestartUnit \
    string:transmission-daemon.service string:replace >/dev/null 2>&1; then
    exit 0
  fi
fi

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  exec systemctl restart transmission-daemon
fi

echo "restartTransmissionDaemon.sh: D-Bus restart failed. Run once on host:" >&2
echo "  sudo ~/Desktop/selfHosted/jellyfin/installTransmissionDockerAccess.sh" >&2
exit 1
