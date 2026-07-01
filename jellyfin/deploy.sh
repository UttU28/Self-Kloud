#!/usr/bin/env bash
# Jellyfin deploy — Docker + nginx (streaming.thatinsaneguy.com)
#
#   ./deploy.sh
#   ./deploy.sh --docker-only
#   sudo ./deploy.sh
#   sudo ./deploy.sh --transmission   # also configure transmission-daemon for media/

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

printStatus()  { echo -e "${GREEN}[jellyfin]${NC} $*"; }
printWarning() { echo -e "${YELLOW}[jellyfin]${NC} $*"; }
printError()   { echo -e "${RED}[jellyfin]${NC} $*" >&2; }
printStep()    { echo -e "${BLUE}[jellyfin]${NC} $*"; }

JELLYFIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../deployLib.sh
source "${JELLYFIN_DIR}/../../dktp/deployLib.sh"
# shellcheck disable=SC1091
source "${JELLYFIN_DIR}/../chitragupt.sh"
DOCKER_ONLY=0
RUN_TRANSMISSION=0

for arg in "$@"; do
  case "$arg" in
    --docker-only) DOCKER_ONLY=1 ;;
    --transmission) RUN_TRANSMISSION=1 ;;
    -h|--help)
      echo "Usage: $0 [--docker-only] [--transmission]"
      echo "  --transmission   Configure system transmission-daemon (requires sudo)"
      exit 0
      ;;
  esac
done

loadEnv() {
  if [ ! -f "${JELLYFIN_DIR}/.env" ]; then
    printError "Missing ${JELLYFIN_DIR}/.env — copy from .env.example"
    exit 1
  fi
  set -a
  # shellcheck disable=SC1091
  source "${JELLYFIN_DIR}/.env"
  set +a
  export JELLYFIN_CONFIG_PATH="${JELLYFIN_CONFIG_PATH:-${JELLYFIN_DIR}/config}"
  export MEDIA_PATH="${MEDIA_PATH:-${JELLYFIN_DIR}/media}"
  export CHITRAGUPT_ROOT="${CHITRAGUPT_ROOT:-/mnt/chitragupt}"
  export JELLYFIN_UID="${JELLYFIN_UID:-1000}"
  export JELLYFIN_GID="${JELLYFIN_GID:-1000}"
}

fixConfigOwnership() {
  local want="${JELLYFIN_UID}:${JELLYFIN_GID}"
  local have
  mkdir -p "${JELLYFIN_CONFIG_PATH}"
  have="$(stat -c '%u:%g' "${JELLYFIN_CONFIG_PATH}" 2>/dev/null || echo "")"
  if [ "$have" = "$want" ]; then
    return 0
  fi
  printStep "Fixing config ownership ${have:-unknown} → ${want}…"
  if [ "$(id -u)" -eq 0 ]; then
    chown -R "${JELLYFIN_UID}:${JELLYFIN_GID}" "${JELLYFIN_CONFIG_PATH}"
  elif command -v docker &>/dev/null; then
    docker run --rm -v "${JELLYFIN_CONFIG_PATH}:/c" alpine:3.20 \
      chown -R "${JELLYFIN_UID}:${JELLYFIN_GID}" /c
  else
    sudo chown -R "${JELLYFIN_UID}:${JELLYFIN_GID}" "${JELLYFIN_CONFIG_PATH}"
  fi
}

deployDocker() {
  printStep "Docker: Jellyfin"
  if ! command -v docker &>/dev/null; then
    printError "Docker is not installed."
    return 1
  fi

  local compose_cmd=""
  if docker compose version &>/dev/null 2>&1; then
    compose_cmd="docker compose"
  elif command -v docker-compose &>/dev/null; then
    compose_cmd="docker-compose"
  else
    printError "Docker Compose is not installed."
    return 1
  fi

  mkdir -p "${MEDIA_PATH}/movies" "${MEDIA_PATH}/tv" "${MEDIA_PATH}/parvatiNambyar" "${JELLYFIN_CONFIG_PATH}"
  ensure_chitragupt_mounted || exit 1
  fixConfigOwnership

  docker rm -f jellyfin 2>/dev/null || true

  cd "$JELLYFIN_DIR"
  $compose_cmd --env-file .env pull jellyfin
  $compose_cmd --env-file .env up -d
  printStatus "Jellyfin started on 127.0.0.1:8096"
}

installNginxSite() {
  local domain="${JELLYFIN_DOMAIN:-streaming.thatinsaneguy.com}"
  local tpl_http="${JELLYFIN_DIR}/nginx/nginx-streaming.http.conf"
  local tpl_https="${JELLYFIN_DIR}/nginx/nginx-streaming.conf"
  local available="/etc/nginx/sites-available/${domain}"
  local enabled="/etc/nginx/sites-enabled/${domain}"
  local le_cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
  local chosen="$tpl_http"

  if [ ! -f "$tpl_http" ]; then
    printError "Missing nginx template: $tpl_http"
    return 1
  fi

  if [ -f "$le_cert" ] && [ -f "$tpl_https" ]; then
    chosen="$tpl_https"
  fi

  printStep "Nginx: ${domain}"
  cp "$chosen" "$available"
  ln -sf "$available" "$enabled"
}

runCertbot() {
  local domain="${JELLYFIN_DOMAIN:-streaming.thatinsaneguy.com}"
  if le_cert_exists "${domain}"; then
    printStatus "Certificate exists for ${domain} — skipped certbot."
    return 0
  fi
  if ! command -v certbot &>/dev/null; then
    return 0
  fi
  printStep "Certbot: ${domain}"
  if [ -n "${CERTBOT_EMAIL:-}" ]; then
    certbot --nginx -d "${domain}" --non-interactive --agree-tos -m "${CERTBOT_EMAIL}" --redirect \
      || printWarning "Certbot issue for ${domain}"
  else
    certbot --nginx -d "${domain}" --non-interactive --agree-tos --redirect \
      || printWarning "Certbot issue for ${domain}"
  fi
}

deployNginx() {
  if ! command -v nginx &>/dev/null; then
    printWarning "nginx not installed — skipping"
    return 0
  fi
  if [ "$(id -u)" -ne 0 ] && [ -z "${SUDO_USER:-}" ]; then
    printWarning "Run with sudo for nginx/certbot"
    return 0
  fi

  installNginxSite || return 1
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  nginx -t
  systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null || true
  runCertbot
  if [ -f "/etc/letsencrypt/live/${JELLYFIN_DOMAIN:-streaming.thatinsaneguy.com}/fullchain.pem" ]; then
    cp "${JELLYFIN_DIR}/nginx/nginx-streaming.conf" \
      "/etc/nginx/sites-available/${JELLYFIN_DOMAIN:-streaming.thatinsaneguy.com}"
    nginx -t && (systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null || true)
  fi
  printStatus "nginx configured for Jellyfin"
}

deployTransmission() {
  local script="${JELLYFIN_DIR}/applyTransmission.sh"
  if [ ! -f "$script" ]; then
    printWarning "Missing ${script}"
    return 1
  fi
  if [ "$(id -u)" -ne 0 ]; then
    printWarning "Transmission setup needs sudo — run: sudo ${script}"
    return 0
  fi
  printStep "Transmission (skipped if daemon already running and healthy)"
  bash "$script"
}

# --- main ---
loadEnv
deployDocker
if [ "$DOCKER_ONLY" -eq 0 ]; then
  deployNginx || printWarning "nginx step had issues"
fi
if [ "$(id -u)" -eq 0 ] || [ "$RUN_TRANSMISSION" -eq 1 ]; then
  deployTransmission || printWarning "transmission step had issues"
fi
printStatus "Done — https://${JELLYFIN_DOMAIN:-streaming.thatinsaneguy.com}"
