#!/usr/bin/env bash
# Immich deploy — Docker + nginx (photos.thatinsaneguy.com)
#
#   ./deploy.sh
#   ./deploy.sh --docker-only
#   sudo ./deploy.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

printStatus()  { echo -e "${GREEN}[immich]${NC} $*"; }
printWarning() { echo -e "${YELLOW}[immich]${NC} $*"; }
printError()   { echo -e "${RED}[immich]${NC} $*" >&2; }
printStep()    { echo -e "${BLUE}[immich]${NC} $*"; }

IMMICH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../deployLib.sh
source "${IMMICH_DIR}/../../dktp/deployLib.sh"
# shellcheck disable=SC1091
source "${IMMICH_DIR}/../chitragupt.sh"
DOCKER_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --docker-only) DOCKER_ONLY=1 ;;
    -h|--help)
      echo "Usage: $0 [--docker-only]"
      exit 0
      ;;
  esac
done

loadEnv() {
  if [ ! -f "${IMMICH_DIR}/.env" ]; then
    printError "Missing ${IMMICH_DIR}/.env — copy from .env.example"
    exit 1
  fi
  set -a
  # shellcheck disable=SC1091
  source "${IMMICH_DIR}/.env"
  set +a
  export IMMICH_UPLOAD_LOCATION="${IMMICH_UPLOAD_LOCATION:-${IMMICH_DIR}/library}"
  export IMMICH_DB_DATA_LOCATION="${IMMICH_DB_DATA_LOCATION:-${IMMICH_DIR}/postgres}"
  export IMMICH_PUBLIC_SPACE="${IMMICH_PUBLIC_SPACE:-${IMMICH_DIR}/../jellyfin/media/publicSpace}"
  export CHITRAGUPT_ROOT="${CHITRAGUPT_ROOT:-/mnt/chitragupt}"
  export IMMICH_PORT="${IMMICH_PORT:-2283}"
}

deployDocker() {
  printStep "Docker: Immich"
  if ! command -v docker &>/dev/null; then
    printError "Docker is not installed."
    return 1
  fi

  if [ -z "${IMMICH_DB_PASSWORD:-}" ] || [ "${IMMICH_DB_PASSWORD}" = "changeMeToRandomAlphanumeric" ]; then
    printError "Set IMMICH_DB_PASSWORD in ${IMMICH_DIR}/.env"
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

  ensure_chitragupt_mounted || exit 1
  mkdir -p "${IMMICH_UPLOAD_LOCATION}" "${IMMICH_DB_DATA_LOCATION}"
  docker rm -f immich-server immich-machine-learning immich-redis immich-postgres 2>/dev/null || true
  cd "$IMMICH_DIR"

  $compose_cmd --env-file .env pull \
    immich-server immich-machine-learning immich-redis immich-database
  $compose_cmd --env-file .env up -d

  printStep "Waiting for Immich on 127.0.0.1:${IMMICH_PORT}…"
  for _ in $(seq 1 45); do
    if ss -tln 2>/dev/null | grep -qE "127\.0\.0\.1:${IMMICH_PORT}\b"; then
      printStatus "Immich listening on port ${IMMICH_PORT}"
      return 0
    fi
    sleep 2
  done
  printWarning "Immich not ready yet — check: cd ${IMMICH_DIR} && $compose_cmd --env-file .env logs -f immich-server"
}

installNginxSite() {
  local domain="${IMMICH_DOMAIN:-photos.thatinsaneguy.com}"
  local tpl_http="${IMMICH_DIR}/nginx/nginx-photos.http.conf"
  local tpl_https="${IMMICH_DIR}/nginx/nginx-photos.conf"
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
  local domain="${IMMICH_DOMAIN:-photos.thatinsaneguy.com}"
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
  if [ -f "/etc/letsencrypt/live/${IMMICH_DOMAIN:-photos.thatinsaneguy.com}/fullchain.pem" ]; then
    cp "${IMMICH_DIR}/nginx/nginx-photos.conf" \
      "/etc/nginx/sites-available/${IMMICH_DOMAIN:-photos.thatinsaneguy.com}"
    nginx -t && (systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null || true)
  fi
  printStatus "nginx configured for Immich"
}

# --- main ---
loadEnv
deployDocker
if [ "$DOCKER_ONLY" -eq 0 ]; then
  deployNginx || printWarning "nginx step had issues"
fi
printStatus "Done — ${IMMICH_PUBLIC_URL:-https://photos.thatinsaneguy.com}"
