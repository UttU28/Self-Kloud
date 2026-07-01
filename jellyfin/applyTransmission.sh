#!/usr/bin/env bash
# Apply Transmission daemon settings for selfHosted Jellyfin media library.
# Stops daemon → writes correct Chitragupt paths → remaps every roddent → restarts.
#
#   sudo ./applyTransmission.sh
#   sudo ./applyTransmission.sh --install
#   sudo ./applyTransmission.sh --force   # re-apply even when daemon is healthy
#
# Reads MEDIA_PATH from jellyfin/.env (default: jellyfin/media).

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

printInfo() { echo -e "${GREEN}[transmission]${NC} $*"; }
printWarn() { echo -e "${YELLOW}[transmission]${NC} $*"; }
printError() { echo -e "${RED}[transmission]${NC} $*" >&2; }

autoInstall=0
forceApply=0
for arg in "$@"; do
  case "$arg" in
    --install) autoInstall=1 ;;
    --force) forceApply=1 ;;
    -h|--help)
      echo "Usage: sudo $0 [--install] [--force]"
      echo "  Stop daemon, apply ${MEDIA_PATH:-media} paths, remap roddents, restart."
      echo "  --install   Install transmission packages when missing (known distros only)."
      echo "  --force     Re-apply settings even when daemon is already running OK."
      exit 0
      ;;
  esac
done

transmissionDaemonHealthy() {
  command -v transmission-remote >/dev/null 2>&1 \
    && systemctl is-active --quiet transmission-daemon 2>/dev/null \
    && transmission-remote --session-info >/dev/null 2>&1
}

transmissionIsInstalled() {
  command -v transmission-daemon >/dev/null 2>&1 && command -v transmission-remote >/dev/null 2>&1
}

printTransmissionInstallHints() {
  local osId="${1:-unknown}"
  local osLike="${2:-}"

  printError "Transmission is not installed (need transmission-daemon + transmission-remote)."
  echo ""
  printInfo "Install for your distro, then re-run this script:"
  echo ""

  case "$osId" in
    arch|manjaro|endeavouros|garuda|cachyos)
      echo "  Arch Linux:"
      echo "    sudo pacman -S --needed transmission-cli"
      ;;
    ubuntu|debian|linuxmint|pop|elementary|raspbian)
      echo "  Ubuntu / Debian:"
      echo "    sudo apt update"
      echo "    sudo apt install -y transmission-daemon transmission-cli"
      ;;
    fedora)
      echo "  Fedora:"
      echo "    sudo dnf install -y transmission-daemon transmission-cli"
      ;;
    rhel|centos|rocky|almalinux|ol)
      echo "  RHEL / Rocky / AlmaLinux:"
      echo "    sudo dnf install -y epel-release"
      echo "    sudo dnf install -y transmission-daemon transmission-cli"
      ;;
    opensuse-tumbleweed|opensuse-leap|sles|suse)
      echo "  openSUSE:"
      echo "    sudo zypper install -y transmission-daemon transmission-cli"
      ;;
    alpine)
      echo "  Alpine:"
      echo "    sudo apk add transmission-daemon transmission-cli"
      ;;
    *)
      if [[ "$osLike" == *debian* ]]; then
        echo "    sudo apt install -y transmission-daemon transmission-cli"
      elif [[ "$osLike" == *rhel* ]] || [[ "$osLike" == *fedora* ]]; then
        echo "    sudo dnf install -y transmission-daemon transmission-cli"
      elif [[ "$osLike" == *arch* ]]; then
        echo "    sudo pacman -S --needed transmission-cli"
      fi
      ;;
  esac

  echo ""
  echo "  Then: sudo systemctl enable --now transmission-daemon"
  echo "  Re-run: sudo ${jellyfinDir}/applyTransmission.sh"
}

tryInstallTransmission() {
  local osId="${1:-unknown}"
  local osLike="${2:-}"

  printInfo "Attempting automatic install (--install)…"

  case "$osId" in
    arch|manjaro|endeavouros|garuda|cachyos)
      pacman -S --needed --noconfirm transmission-cli
      ;;
    ubuntu|debian|linuxmint|pop|elementary|raspbian)
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y transmission-daemon transmission-cli
      ;;
    fedora|rhel|centos|rocky|almalinux|ol)
      dnf install -y epel-release || true
      dnf install -y transmission-daemon transmission-cli
      ;;
    opensuse-tumbleweed|opensuse-leap|sles|suse)
      zypper --non-interactive install transmission-daemon transmission-cli
      ;;
    alpine)
      apk add transmission-daemon transmission-cli
      ;;
    *)
      if [[ "$osLike" == *debian* ]]; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y transmission-daemon transmission-cli
      elif [[ "$osLike" == *rhel* ]] || [[ "$osLike" == *fedora* ]]; then
        dnf install -y transmission-daemon transmission-cli
      elif [[ "$osLike" == *arch* ]]; then
        pacman -S --needed --noconfirm transmission-cli
      else
        return 1
      fi
      ;;
  esac
}

ensureTransmission() {
  if transmissionIsInstalled; then
    printInfo "Transmission CLI found: $(command -v transmission-remote)"
    return 0
  fi

  local osId="unknown"
  local osLike=""
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    osId="${ID:-unknown}"
    osLike="${ID_LIKE:-}"
  fi

  if [ "$autoInstall" -eq 1 ] && tryInstallTransmission "$osId" "$osLike" \
    && transmissionIsInstalled; then
    printInfo "Transmission installed."
    systemctl enable --now transmission-daemon 2>/dev/null || true
    return 0
  fi

  printTransmissionInstallHints "$osId" "$osLike"
  exit 1
}

stopTransmissionDaemon() {
  if systemctl is-active --quiet transmission-daemon 2>/dev/null; then
    if transmission-remote --session-info >/dev/null 2>&1; then
      printInfo "Pausing all roddents…"
      transmission-remote -t all --stop >/dev/null 2>&1 || true
    fi
    printInfo "Stopping transmission-daemon…"
    systemctl stop transmission-daemon
    sleep 1
  fi
}

startTransmissionDaemon() {
  systemctl enable transmission-daemon 2>/dev/null || true
  printInfo "Starting transmission-daemon…"
  systemctl start transmission-daemon
  sleep 2

  if ! transmission-remote --session-info >/dev/null 2>&1; then
    printError "Transmission RPC not reachable after start"
    systemctl status transmission-daemon --no-pager || true
    exit 1
  fi
}

# Map legacy Docker / Desktop paths → current MEDIA_PATH subfolders.
resolveTorrentLocation() {
  local loc="$1"

  case "$loc" in
    /app/media/movies|/app/media/movies/*|/media/movies|/media/movies/*)
      echo "${mediaPath}/movies"
      return
      ;;
    /app/media/tv|/app/media/tv/*|/media/tv|/media/tv/*)
      echo "${mediaPath}/tv"
      return
      ;;
    /app/media/parvatiNambyar|/app/media/parvatiNambyar/*|/media/parvatiNambyar|/media/parvatiNambyar/*)
      echo "${mediaPath}/parvatiNambyar"
      return
      ;;
    /app/media/publicSpace|/app/media/publicSpace/*|/media/publicSpace|/media/publicSpace/*)
      echo "${mediaPath}/publicSpace"
      return
      ;;
  esac

  case "$loc" in
    *"/jellyfin/media/movies"|*"/jellyfin/media/movies/"*)
      echo "${mediaPath}/movies"
      return
      ;;
    *"/jellyfin/media/tv"|*"/jellyfin/media/tv/"*)
      echo "${mediaPath}/tv"
      return
      ;;
    *"/jellyfin/media/parvatiNambyar"|*"/jellyfin/media/parvatiNambyar/"*)
      echo "${mediaPath}/parvatiNambyar"
      return
      ;;
    *"/jellyfin/media/publicSpace"|*"/jellyfin/media/publicSpace/"*)
      echo "${mediaPath}/publicSpace"
      return
      ;;
  esac

  case "$loc" in
    "${mediaPath}/movies"|"${mediaPath}/movies/"*)
      echo "${mediaPath}/movies"
      return
      ;;
    "${mediaPath}/tv"|"${mediaPath}/tv/"*)
      echo "${mediaPath}/tv"
      return
      ;;
    "${mediaPath}/parvatiNambyar"|"${mediaPath}/parvatiNambyar/"*)
      echo "${mediaPath}/parvatiNambyar"
      return
      ;;
    "${mediaPath}/publicSpace"|"${mediaPath}/publicSpace/"*)
      echo "${mediaPath}/publicSpace"
      return
      ;;
    "${mediaPath}"|"${mediaPath}/"*)
      echo "${mediaPath}"
      return
      ;;
  esac

  # Unknown legacy path — default to movies (most roddents)
  echo "${mediaPath}/movies"
}

relocateAllTorrents() {
  local tid loc target
  printInfo "Remapping roddent locations to ${mediaPath}…"

  transmission-remote -w "${mediaPath}" >/dev/null
  transmission-remote -c "${incompleteDir}" >/dev/null

  while IFS= read -r tid; do
    [ -z "$tid" ] && continue
    loc="$(transmission-remote -t "$tid" -i 2>/dev/null | awk -F': ' '/^  Location:/ {print $2; exit}')"
    target="$(resolveTorrentLocation "$loc")"
    if [ "$loc" != "$target" ]; then
      printInfo "  roddent ${tid}: ${loc} → ${target}"
    fi
    transmission-remote -t "$tid" --find "${target}" >/dev/null 2>&1 || true
    transmission-remote -t "$tid" --verify >/dev/null 2>&1 || true
    transmission-remote -t "$tid" --start >/dev/null 2>&1 || true
  done < <(transmission-remote -l 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+/ {print $1}')
}

jellyfinDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${jellyfinDir}/../chitragupt.sh"
envFile="${jellyfinDir}/.env"
settingsTemplate="${jellyfinDir}/transmissionDaemon.settings.example.json"
transmissionUser="transmission"

if [ "$(id -u)" -ne 0 ]; then
  printError "Run with sudo: sudo ${jellyfinDir}/applyTransmission.sh"
  exit 1
fi

ensureTransmission

if [ "$forceApply" -eq 0 ] && transmissionDaemonHealthy; then
  printInfo "transmission-daemon is running and RPC OK — skipped (no stop/restart)."
  printInfo "To re-apply paths/settings anyway: sudo ${jellyfinDir}/applyTransmission.sh --force"
  exit 0
fi

if ! transmissionDaemonHealthy; then
  printWarn "transmission-daemon not running or RPC unreachable — will stop, reconfigure, and restart."
fi

if [ ! -f "$settingsTemplate" ]; then
  printError "Missing settings template: ${settingsTemplate}"
  exit 1
fi

if [ -f "$envFile" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$envFile"
  set +a
fi

realUser="${SUDO_USER:-${USER:-dedsec995}}"
realHome="$(getent passwd "$realUser" | cut -d: -f6)"
userSettings="${realHome}/.config/transmission-daemon/settings.json"
systemSettings="/var/lib/transmission/.config/transmission-daemon/settings.json"

mediaPath="${MEDIA_PATH:-${jellyfinDir}/media}"
export CHITRAGUPT_ROOT="${CHITRAGUPT_ROOT:-/mnt/chitragupt}"
ensure_chitragupt_mounted || exit 1
mediaPath="$(readlink -f "$mediaPath")"
incompleteDir="${mediaPath}/.incomplete"

printInfo "Media path: ${mediaPath}"

stopTransmissionDaemon

mkdir -p \
  "${mediaPath}/movies" \
  "${mediaPath}/tv" \
  "${mediaPath}/parvatiNambyar" \
  "${mediaPath}/publicSpace" \
  "${incompleteDir}"
chown -R "${realUser}:${realUser}" "${mediaPath}"

setTransmissionAcls() {
  local dir
  local mediaOwnerUid
  mediaOwnerUid="$(id -u "${realUser}" 2>/dev/null || echo 1000)"
  if _uses_chitragupt_paths "$mediaPath"; then
    for dir in /mnt "${CHITRAGUPT_ROOT}" "${CHITRAGUPT_ROOT}/jellyfin"; do
      if [ -d "$dir" ]; then
        setfacl -m "u:${transmissionUser}:x" "$dir"
        setfacl -m "u:${realUser}:x" "$dir"
        printInfo "ACL traverse: ${dir}"
      fi
    done
  else
    for dir in "${realHome}" "${realHome}/Desktop" "${realHome}/Desktop/selfHosted" "${jellyfinDir}"; do
      if [ -d "$dir" ]; then
        setfacl -m "u:${transmissionUser}:x" "$dir"
        setfacl -m "u:${realUser}:x" "$dir"
        printInfo "ACL traverse: ${dir}"
      fi
    done
  fi
  setfacl -R -m "u:${transmissionUser}:rwx" "${mediaPath}"
  setfacl -R -d -m "u:${transmissionUser}:rwx" "${mediaPath}"
  setfacl -R -m "u:${realUser}:rwx" "${mediaPath}"
  setfacl -R -d -m "u:${realUser}:rwx" "${mediaPath}"
  printInfo "ACL read/write on ${mediaPath} for ${transmissionUser} and ${realUser} (uid ${mediaOwnerUid}, Apeksha Docker appuser)"
}

relocateScript="${jellyfinDir}/relocateCompletedTorrents.sh"
chmod +x "$relocateScript" 2>/dev/null || true

python3 - "$settingsTemplate" "$userSettings" "$mediaPath" "$incompleteDir" <<'PY'
import json
import sys
from pathlib import Path

template, userOut, media, incomplete = sys.argv[1:5]
data = json.loads(Path(template).read_text())
data["download-dir"] = media
data["incomplete-dir"] = incomplete
data["incomplete-dir-enabled"] = True
data["download-queue-enabled"] = True
data["download-queue-size"] = 8
data["start-added-torrents"] = True
data["start_paused"] = False
data["script-torrent-done-enabled"] = False
data["script-torrent-done-filename"] = ""
data["script-torrent-done-seeding-enabled"] = False
data["script-torrent-done-seeding-filename"] = ""
Path(userOut).parent.mkdir(parents=True, exist_ok=True)
Path(userOut).write_text(json.dumps(data, indent=4) + "\n")
print(userOut)
PY

chown "${realUser}:${realUser}" "${userSettings}"
printInfo "Updated user settings: ${userSettings}"

mkdir -p "$(dirname "$systemSettings")"
python3 - "$userSettings" "$systemSettings" <<'PY'
import json
import sys
from pathlib import Path

src, dst = sys.argv[1:3]
Path(dst).write_text(Path(src).read_text())
print(dst)
PY

chown -R "${transmissionUser}:${transmissionUser}" "$(dirname "$systemSettings")"
printInfo "Updated system settings: ${systemSettings}"

setTransmissionAcls

startTransmissionDaemon
relocateAllTorrents

printInfo "Transmission session:"
transmission-remote --session-info 2>/dev/null | grep -E 'Download directory|Incomplete' || true
printInfo "Relocate completed (CLI): ${relocateScript}"
printInfo "Relocate completed (UI):  Apeksha → Move completed button"
echo ""
transmission-remote -l 2>/dev/null || true
printInfo "Done."
printInfo "ACLs allow transmission + ${realUser} (uid $(id -u ${realUser})) to read/write ${mediaPath}"
