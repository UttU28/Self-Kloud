#!/usr/bin/env bash
# One-time host setup so Apeksha (Docker) can switch transmission proxy mode.
#
#   sudo ./installTransmissionDockerAccess.sh
#
# Installs:
#   - systemd drop-in: config in ~/.config/transmission-daemon + Restart=always
#   - ExecStartPre: applies settings.apeksha.json written by Docker (no permission fight)
#   - ACLs: dedsec995 + transmission both read/write config dir

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${GREEN}[transmission-docker]${NC} $*"; }
warn() { echo -e "${YELLOW}[transmission-docker]${NC} $*"; }
err() { echo -e "${RED}[transmission-docker]${NC} $*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  err "Run with sudo: sudo $0"
  exit 1
fi

realUser="${SUDO_USER:-dedsec995}"
realHome="$(getent passwd "$realUser" | cut -d: -f6)"
configDir="${realHome}/.config/transmission-daemon"
stagingFile="${configDir}/settings.apeksha.json"
dropInDir="/etc/systemd/system/transmission-daemon.service.d"
polkitRule="/etc/polkit-1/rules.d/50-apeksha-transmission-restart.rules"
realUid="$(id -u "$realUser")"

info "User: ${realUser} (uid ${realUid})"
info "Config dir: ${configDir}"

mkdir -p "${configDir}" "${dropInDir}"
chown -R "${realUser}:${realUser}" "${configDir}"

cat > "${dropInDir}/apeksha-docker.conf" <<EOF
[Service]
ExecStartPre=/bin/sh -c 'if [ -f ${stagingFile} ]; then cp ${stagingFile} ${configDir}/settings.json && chown transmission:transmission ${configDir}/settings.json; fi'
ExecStart=
ExecStart=/usr/bin/transmission-daemon -f --log-level=error --config-dir ${configDir}
Restart=always
RestartSec=2
EOF

for dir in "${realHome}" "${realHome}/.config"; do
  if [ -d "$dir" ]; then
    setfacl -m "u:transmission:x" "$dir" 2>/dev/null || true
    setfacl -m "u:${realUser}:x" "$dir" 2>/dev/null || true
  fi
done
setfacl -R -m "u:transmission:rwx" "${configDir}" 2>/dev/null || true
setfacl -R -m "u:${realUser}:rwx" "${configDir}" 2>/dev/null || true
setfacl -R -m "m:rwx" "${configDir}" 2>/dev/null || true
setfacl -R -d -m "u:transmission:rwx" "${configDir}" 2>/dev/null || true
setfacl -R -d -m "u:${realUser}:rwx" "${configDir}" 2>/dev/null || true
setfacl -R -d -m "m:rwx" "${configDir}" 2>/dev/null || true

cat > "${polkitRule}" <<EOF
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.systemd1.manage-units" &&
        action.lookup("unit") == "transmission-daemon.service" &&
        subject.uid == ${realUid}) {
        return polkit.Result.YES;
    }
});
EOF

systemSettings="/var/lib/transmission/.config/transmission-daemon/settings.json"
if [ ! -f "${configDir}/settings.json" ] && [ -f "${systemSettings}" ]; then
  cp "${systemSettings}" "${configDir}/settings.json"
  chown "${realUser}:${realUser}" "${configDir}/settings.json"
  info "Copied existing system settings → ${configDir}/settings.json"
fi

systemctl daemon-reload
systemctl restart transmission-daemon

if transmission-remote --session-info >/dev/null 2>&1; then
  info "transmission-daemon is running and RPC OK."
  transmission-remote --session-info 2>/dev/null | grep -E 'Configuration directory|Download directory' || true
else
  warn "transmission-daemon restarted but RPC not reachable — check: systemctl status transmission-daemon"
fi

info "Done. Rebuild Apeksha: cd ~/Desktop/Apeksha/backend/deploy && docker compose up -d --build bhasini-api"
