#!/usr/bin/env bash
# Nextcloud deploy — Docker (MariaDB + Redis) + nginx (kloud.thatinsaneguy.com)
#
#   ./deploy.sh
#   ./deploy.sh --docker-only
#   sudo ./deploy.sh
#   ./deploy.sh --clean       # wipe data/db + fresh install from .env
#   ./deploy.sh -r

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

printStatus()  { echo -e "${GREEN}[nextcloud]${NC} $*"; }
printWarning() { echo -e "${YELLOW}[nextcloud]${NC} $*"; }
printError()   { echo -e "${RED}[nextcloud]${NC} $*" >&2; }
printStep()    { echo -e "${BLUE}[nextcloud]${NC} $*"; }
banner() {
  echo ""
  echo -e "${CYAN}================================================================================${NC}"
  echo -e "${CYAN} $*${NC}"
  echo -e "${CYAN}================================================================================${NC}"
  echo ""
}

NEXTCLOUD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../deploy-lib.sh
source "${NEXTCLOUD_DIR}/../../deploy-lib.sh"
# shellcheck disable=SC1091
source "${NEXTCLOUD_DIR}/../chitragupt.sh"
DOCKER_ONLY=0
REMOVE=0
FINISH_INSTALL=0
CLEAN_INSTALL=0
# www-data inside official Nextcloud image
NEXTCLOUD_UID=33
NEXTCLOUD_GID=33

for arg in "$@"; do
  case "$arg" in
    --docker-only) DOCKER_ONLY=1 ;;
    --remove|-r) REMOVE=1 ;;
    --finish-install) FINISH_INSTALL=1 ;;
    --clean) CLEAN_INSTALL=1 ;;
    -h|--help)
      echo "Usage: $0 [--docker-only] [--remove|-r] [--finish-install] [--clean]"
      echo "  Deploy Nextcloud + MariaDB + Redis. Use sudo for nginx/certbot."
      echo "  --remove, -r        Interactive remove: containers, data, or both"
      echo "  --finish-install    Run occ install using .env (if setup wizard stuck)"
      echo "  --clean             Wipe data/db and run a fresh install from .env"
      exit 0
      ;;
  esac
done

loadEnv() {
  if [ ! -f "${NEXTCLOUD_DIR}/.env" ]; then
    printError "Missing ${NEXTCLOUD_DIR}/.env — copy from .env.example"
    exit 1
  fi
  set -a
  # shellcheck disable=SC1091
  source "${NEXTCLOUD_DIR}/.env"
  set +a
  export NEXTCLOUD_DATA_PATH="${NEXTCLOUD_DATA_PATH:-${NEXTCLOUD_DIR}/data}"
  export NEXTCLOUD_DB_PATH="${NEXTCLOUD_DB_PATH:-${NEXTCLOUD_DIR}/db}"
  export CHITRAGUPT_ROOT="${CHITRAGUPT_ROOT:-/mnt/chitragupt}"
  export JELLYFIN_MEDIA_PATH="${JELLYFIN_MEDIA_PATH:-${CHITRAGUPT_ROOT}/jellyfin/media}"
  export NEXTCLOUD_PORT="${NEXTCLOUD_PORT:-9270}"
  export NEXTCLOUD_DOMAIN="${NEXTCLOUD_DOMAIN:-kloud.thatinsaneguy.com}"
}

validateEnv() {
  local bad=0
  for var in MYSQL_PASSWORD MYSQL_ROOT_PASSWORD NEXTCLOUD_ADMIN_PASSWORD NEXTCLOUD_ADMIN_USER; do
    local val="${!var:-}"
    if [ -z "$val" ] || [[ "$val" == changeMe* ]]; then
      printError "Set ${var} in ${NEXTCLOUD_DIR}/.env (no placeholder values)"
      bad=1
    fi
  done
  [ "$bad" -eq 0 ] || exit 1
}

checkRootDiskSpace() {
  local avail_kb
  avail_kb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -n "$avail_kb" && "$avail_kb" -lt 524288 ]]; then
    printWarning "Root filesystem (/) is low on space ($(df -h / | awk 'NR==2 {print $4 " free"}'))."
    printWarning "Docker uses / for container /tmp — install may fail until you free space."
    printWarning "Try: docker system prune -f   and   sudo pacman -Sc"
    if [[ -n "$avail_kb" && "$avail_kb" -lt 102400 ]]; then
      printError "Less than 100MB free on / — aborting. Free disk space first."
      exit 1
    fi
  fi
}

prepareTempDirectory() {
  mkdir -p "${NEXTCLOUD_DATA_PATH}/data/tmp"
  if [ "$(id -u)" -eq 0 ]; then
    chown -R "${NEXTCLOUD_UID}:${NEXTCLOUD_GID}" "${NEXTCLOUD_DATA_PATH}/data/tmp"
  fi

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx nextcloud; then
    printStep "Configuring temp directory on data volume (avoids full /tmp on root disk)…"
    docker cp "${NEXTCLOUD_DIR}/config-snippets/temp.config.php" \
      nextcloud:/var/www/html/config/temp.config.php
    docker exec nextcloud chown www-data:www-data /var/www/html/config/temp.config.php
    docker exec -u www-data nextcloud mkdir -p /var/www/html/data/tmp
  fi
}

fixDataOwnership() {
  local want="${NEXTCLOUD_UID}:${NEXTCLOUD_GID}"
  local have
  mkdir -p "${NEXTCLOUD_DATA_PATH}" "${NEXTCLOUD_DB_PATH}"
  have="$(stat -c '%u:%g' "${NEXTCLOUD_DATA_PATH}" 2>/dev/null || echo "")"
  if [ "$have" = "$want" ]; then
    return 0
  fi
  printStep "Fixing data ownership ${have:-unknown} → ${want}…"
  if [ "$(id -u)" -eq 0 ]; then
    chown -R "${NEXTCLOUD_UID}:${NEXTCLOUD_GID}" "${NEXTCLOUD_DATA_PATH}"
  elif command -v docker &>/dev/null; then
    docker run --rm -v "${NEXTCLOUD_DATA_PATH}:/c" alpine:3.20 \
      chown -R "${NEXTCLOUD_UID}:${NEXTCLOUD_GID}" /c
  else
    sudo chown -R "${NEXTCLOUD_UID}:${NEXTCLOUD_GID}" "${NEXTCLOUD_DATA_PATH}"
  fi
}

deployDocker() {
  printStep "Docker: Nextcloud + MariaDB + Redis"
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

  fixDataOwnership
  ensure_chitragupt_mounted || exit 1
  warn_chitragupt_bind_paths "Jellyfin media" "${JELLYFIN_MEDIA_PATH}"
  docker rm -f nextcloud nextcloud-db nextcloud-redis 2>/dev/null || true
  cd "$NEXTCLOUD_DIR"

  $compose_cmd --env-file .env pull nextcloud nextcloud-db nextcloud-redis
  $compose_cmd --env-file .env up -d

  waitForNextcloud
}

isNextcloudInstalled() {
  local status
  status="$(curl -sf "http://127.0.0.1:${NEXTCLOUD_PORT}/status.php" 2>/dev/null || echo "")"
  [[ "$status" == *'"installed":true'* ]]
}

waitForNextcloud() {
  printStep "Waiting for Nextcloud on 127.0.0.1:${NEXTCLOUD_PORT}…"
  for _ in $(seq 1 60); do
    if ss -tln 2>/dev/null | grep -qE "127\.0\.0\.1:${NEXTCLOUD_PORT}\b"; then
      if curl -sf "http://127.0.0.1:${NEXTCLOUD_PORT}/status.php" >/dev/null 2>&1; then
        printStatus "Nextcloud listening on port ${NEXTCLOUD_PORT}"
        return 0
      fi
    fi
    sleep 3
  done
  printWarning "Nextcloud not ready yet — check logs"
  return 1
}

resetDatabase() {
  printStep "Resetting MariaDB database ${MYSQL_DATABASE:-nextcloud}…"
  docker exec nextcloud-db mariadb -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "
    DROP DATABASE IF EXISTS \`${MYSQL_DATABASE:-nextcloud}\`;
    CREATE DATABASE \`${MYSQL_DATABASE:-nextcloud}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
    GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE:-nextcloud}\`.* TO '${MYSQL_USER:-nextcloud}'@'%';
    FLUSH PRIVILEGES;
  "
}

resetAppConfig() {
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx nextcloud; then
    printStep "Resetting Nextcloud config (partial install)…"
    docker exec -u www-data nextcloud sh -c '
      rm -f /var/www/html/config/config.php
      touch /var/www/html/config/CAN_INSTALL
    ' 2>/dev/null || true
  fi
}

repairPartialInstall() {
  if isNextcloudInstalled; then
    return 0
  fi
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx nextcloud-db; then
    return 0
  fi

  local user_count
  user_count="$(docker exec nextcloud-db mariadb \
    -u"${MYSQL_USER:-nextcloud}" -p"${MYSQL_PASSWORD}" \
    "${MYSQL_DATABASE:-nextcloud}" -Nse "SELECT COUNT(*) FROM oc_users;" \
    2>/dev/null || echo "0")"

  if [ "${user_count:-0}" -gt 0 ]; then
    printWarning "Partial install detected — resetting DB and config…"
    resetDatabase
    resetAppConfig
    sleep 2
  fi
}

configureTrustedDomains() {
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx nextcloud; then
    return 0
  fi
  local lan_ip
  lan_ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  printStep "Setting trusted_domains (${NEXTCLOUD_DOMAIN}${lan_ip:+, ${lan_ip}})…"
  docker exec -u www-data nextcloud php occ config:system:set trusted_domains 1 --value="${NEXTCLOUD_DOMAIN}"
  if [ -n "$lan_ip" ]; then
    docker exec -u www-data nextcloud php occ config:system:set trusted_domains 2 --value="${lan_ip}"
  fi
  docker exec -u www-data nextcloud php occ config:system:set overwritehost --value="${NEXTCLOUD_DOMAIN}"
  docker exec -u www-data nextcloud php occ config:system:set overwriteprotocol --value=https
}

configureJellyfinExternalStorage() {
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx nextcloud; then
    return 0
  fi
  if ! isNextcloudInstalled; then
    return 0
  fi

  local user="${NEXTCLOUD_ADMIN_USER:-admin}"
  local media_path="${JELLYFIN_MEDIA_PATH}"
  local id

  printStep "Configuring Jellyfin external storage (removing Immich if present)…"
  docker exec -u www-data nextcloud php occ app:enable files_external >/dev/null 2>&1 || true

  while read -r id; do
    [ -n "$id" ] || continue
    docker exec -u www-data nextcloud php occ files_external:delete -y "$id" >/dev/null 2>&1 || true
  done < <(
    docker exec -u www-data nextcloud php occ files_external:list --all 2>/dev/null \
      | awk -F'|' '/^\| [0-9]+ / {gsub(/ /, "", $2); print $2}'
  )

  printStep "Creating Jellyfin Media mount for ${user}…"
  docker exec -u www-data nextcloud php occ files_external:create \
    "Jellyfin Media" local null::null \
    --user "$user" \
    -c "datadir=${media_path}" >/dev/null 2>&1 || true

  printStep "Scanning Jellyfin Media (may take a minute)…"
  docker exec -u www-data nextcloud php occ files:scan "$user" \
    --path="/${user}/files/Jellyfin Media" 2>/dev/null || true
  printStatus "Jellyfin external storage ready"
}

finishInstall() {
  if isNextcloudInstalled; then
    printStatus "Nextcloud already installed — skip occ"
    configureTrustedDomains
    configureJellyfinExternalStorage
    return 0
  fi

  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx nextcloud; then
    printError "nextcloud container is not running"
    return 1
  fi

  repairPartialInstall

  prepareTempDirectory

  printStep "Installing via occ (admin: ${NEXTCLOUD_ADMIN_USER} from .env)…"
  if docker exec -u www-data nextcloud php occ maintenance:install \
    --admin-user "${NEXTCLOUD_ADMIN_USER}" \
    --admin-pass "${NEXTCLOUD_ADMIN_PASSWORD}" \
    --data-dir /var/www/html/data \
    --database mysql \
    --database-name "${MYSQL_DATABASE:-nextcloud}" \
    --database-user "${MYSQL_USER:-nextcloud}" \
    --database-pass "${MYSQL_PASSWORD}" \
    --database-host nextcloud-db; then
    printStatus "Nextcloud install complete"
    configureTrustedDomains
    configureJellyfinExternalStorage
    printStatus "Log in at https://${NEXTCLOUD_DOMAIN} as ${NEXTCLOUD_ADMIN_USER}"
    return 0
  fi

  printError "occ install failed."
  printWarning "Try: sudo ./deploy.sh --clean"
  return 1
}

installNginxSite() {
  local domain="${NEXTCLOUD_DOMAIN}"
  local tpl_http="${NEXTCLOUD_DIR}/nginx/nginx-kloud.http.conf"
  local tpl_https="${NEXTCLOUD_DIR}/nginx/nginx-kloud.conf"
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
  local domain="${NEXTCLOUD_DOMAIN}"
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
  if [ -f "/etc/letsencrypt/live/${NEXTCLOUD_DOMAIN}/fullchain.pem" ]; then
    cp "${NEXTCLOUD_DIR}/nginx/nginx-kloud.conf" \
      "/etc/nginx/sites-available/${NEXTCLOUD_DOMAIN}"
    nginx -t && (systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null || true)
  fi
  printStatus "nginx configured for Nextcloud"
}

composeCmd() {
  if docker compose version &>/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose &>/dev/null; then
    echo "docker-compose"
  else
    return 1
  fi
}

stopContainers() {
  if ! command -v docker &>/dev/null; then
    printWarning "Docker not found — skipping containers"
    return 0
  fi
  local compose_cmd
  if compose_cmd="$(composeCmd)"; then
    printStep "Stopping compose stack…"
    (cd "$NEXTCLOUD_DIR" && $compose_cmd --env-file .env down --remove-orphans 2>/dev/null) \
      || (cd "$NEXTCLOUD_DIR" && $compose_cmd down --remove-orphans 2>/dev/null) \
      || true
  fi
  printStep "Removing containers…"
  docker rm -f nextcloud nextcloud-db nextcloud-redis 2>/dev/null || true
  printStatus "Containers removed."
}

deleteData() {
  for path in "${NEXTCLOUD_DATA_PATH}" "${NEXTCLOUD_DB_PATH}"; do
    if [ -e "$path" ]; then
      printStep "Removing ${path}…"
      rm -rf "$path"
      printStatus "Removed ${path}"
    else
      printStatus "Skip (missing): ${path}"
    fi
  done
}

showRemoveMenu() {
  echo ""
  echo -e "${CYAN}Nextcloud remove${NC}"
  echo "  0 — Remove containers and data (full reset)"
  echo "  1 — Remove containers only (keep data/ and db/)"
  echo "  2 — Remove data only (keep containers running)"
  echo ""
}

removeStack() {
  banner "Remove Nextcloud"

  if [ -f "${NEXTCLOUD_DIR}/.env" ]; then
    loadEnv
  else
    export NEXTCLOUD_DATA_PATH="${NEXTCLOUD_DIR}/data"
    export NEXTCLOUD_DB_PATH="${NEXTCLOUD_DIR}/db"
    export NEXTCLOUD_DOMAIN="kloud.thatinsaneguy.com"
  fi

  showRemoveMenu
  local choice
  read -r -p "Enter choice [1]: " choice
  choice="${choice:-1}"

  case "$choice" in
    0)
      printWarning "Will remove containers AND delete:"
      echo "  ${NEXTCLOUD_DATA_PATH}"
      echo "  ${NEXTCLOUD_DB_PATH}"
      echo ""
      local reply
      read -r -p "Continue? [y/N] " reply
      if [[ ! "${reply:-}" =~ ^[yY]$ ]]; then
        printStatus "Cancelled."
        exit 0
      fi
      stopContainers
      deleteData
      ;;
    1)
      stopContainers
      ;;
    2)
      printWarning "Will delete data on disk (containers unchanged):"
      echo "  ${NEXTCLOUD_DATA_PATH}"
      echo "  ${NEXTCLOUD_DB_PATH}"
      echo ""
      local reply
      read -r -p "Continue? [y/N] " reply
      if [[ ! "${reply:-}" =~ ^[yY]$ ]]; then
        printStatus "Cancelled."
        exit 0
      fi
      deleteData
      ;;
    *)
      printError "Invalid choice: ${choice} (use 0, 1, or 2)"
      exit 1
      ;;
  esac

  banner "Done"
  printStatus "Redeploy: cd ${NEXTCLOUD_DIR} && sudo ./deploy.sh"
}

if [ "$REMOVE" -eq 1 ]; then
  removeStack
  exit 0
fi

if [ "$FINISH_INSTALL" -eq 1 ]; then
  banner "Finish Nextcloud install"
  loadEnv
  validateEnv
  finishInstall || exit 1
  exit 0
fi

if [ "$CLEAN_INSTALL" -eq 1 ]; then
  banner "Clean Nextcloud install"
  loadEnv
  validateEnv
  checkRootDiskSpace
  stopContainers
  deleteData
  deployDocker
  finishInstall || exit 1
  if [ "$DOCKER_ONLY" -eq 0 ]; then
    banner "Nginx + SSL (${NEXTCLOUD_DOMAIN})"
    deployNginx || printWarning "nginx step had issues"
  fi
  banner "Done"
  printStatus "Log in: https://${NEXTCLOUD_DOMAIN}  user=${NEXTCLOUD_ADMIN_USER}"
  exit 0
fi

# --- main ---
START_TS=$(date +%s)
banner "Nextcloud deploy"
loadEnv
validateEnv
checkRootDiskSpace
deployDocker
finishInstall || exit 1
if [ "$DOCKER_ONLY" -eq 0 ]; then
  banner "Nginx + SSL (${NEXTCLOUD_DOMAIN})"
  deployNginx || printWarning "nginx step had issues"
fi
ELAPSED=$(( $(date +%s) - START_TS ))
banner "Deploy summary (${ELAPSED}s)"
printStatus "Done — https://${NEXTCLOUD_DOMAIN}"
