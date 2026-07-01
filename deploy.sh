#!/usr/bin/env bash
# Deploy selfHosted media stack: Jellyfin, Immich, Transmission, Nextcloud.
#
#   sudo bash ~/Desktop/selfHosted/deploy.sh           # interactive menu
#   sudo bash ~/Desktop/selfHosted/deploy.sh 0       # Jellyfin + Immich
#   sudo bash ~/Desktop/selfHosted/deploy.sh 1       # Jellyfin only
#   sudo bash ~/Desktop/selfHosted/deploy.sh 2       # Immich only
#   sudo bash ~/Desktop/selfHosted/deploy.sh 3       # Transmission only (no Docker)
#   sudo bash ~/Desktop/selfHosted/deploy.sh 4       # Nextcloud only
#   sudo bash ~/Desktop/selfHosted/deploy.sh 0,3     # Jellyfin + Immich + Transmission
#
#   0 = Jellyfin + Immich   1 = Jellyfin   2 = Immich   3 = Transmission   4 = Nextcloud
#
# Optional env: CERTBOT_EMAIL, DOCKER_ONLY=1

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JELLYFIN_DEPLOY="${ROOT}/jellyfin/deploy.sh"
IMMICH_DEPLOY="${ROOT}/immich/deploy.sh"
TRANSMISSION_SCRIPT="${ROOT}/jellyfin/applyTransmission.sh"
NEXTCLOUD_DEPLOY="${ROOT}/nextcloud/deploy.sh"
APEKSHA_COMPOSE="/home/dedsec995/Desktop/Apeksha/backend/deploy/docker-compose.yml"
APEKSHA_ENV="/home/dedsec995/Desktop/Apeksha/backend/.env"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

step()   { echo -e "${BLUE}[SELFHOSTED]${NC} $*"; }
info()   { echo -e "${GREEN}[SELFHOSTED]${NC} $*"; }
warn()   { echo -e "${YELLOW}[SELFHOSTED]${NC} $*" >&2; }
err()    { echo -e "${RED}[SELFHOSTED]${NC} $*" >&2; }
banner() {
  echo ""
  echo -e "${CYAN}================================================================================${NC}"
  echo -e "${CYAN} $*${NC}"
  echo -e "${CYAN}================================================================================${NC}"
  echo ""
}

RUN_JELLYFIN=0
RUN_IMMICH=0
RUN_TRANSMISSION=0
RUN_NEXTCLOUD=0
DOCKER_ONLY="${DOCKER_ONLY:-0}"

usage() {
  cat <<'EOF'
Usage: deploy.sh [selection]

Selection (prompts interactively when omitted):
  0       Jellyfin + Immich
  1       Jellyfin (+ streaming nginx)
  2       Immich (+ photos nginx)
  3       Transmission daemon only (system service, no Docker)
  4       Nextcloud (+ cloud nginx)
  1,3,4   Multiple (comma-separated)

Examples:
  sudo bash ~/Desktop/selfHosted/deploy.sh
  sudo bash ~/Desktop/selfHosted/deploy.sh 0
  sudo bash ~/Desktop/selfHosted/deploy.sh 4
  sudo bash ~/Desktop/selfHosted/deploy.sh 3
  sudo bash ~/Desktop/selfHosted/deploy.sh 0,3
  DOCKER_ONLY=1 sudo bash ~/Desktop/selfHosted/deploy.sh 0

Optional env:
  CERTBOT_EMAIL     Let's Encrypt contact
  DOCKER_ONLY=1     Skip nginx/certbot (containers only)
EOF
}

is_numeric_selection() {
  local raw="${1//[[:space:]]/}"
  [[ "$raw" =~ ^[0-4]+(,[0-4]+)*$ ]]
}

show_selection_menu() {
  echo ""
  echo -e "${CYAN}Select services to deploy${NC}"
  echo "  0 — Jellyfin + Immich"
  echo "  1 — Jellyfin (streaming.thatinsaneguy.com)"
  echo "  2 — Immich (photos.thatinsaneguy.com)"
  echo "  3 — Transmission (roddent downloads, no Docker)"
  echo "  4 — Nextcloud (kloud.thatinsaneguy.com)"
  echo ""
  echo "Examples: 0   1   2   3   4   0,3   1,2,3,4"
  echo ""
  echo "Optional env: DOCKER_ONLY=1  CERTBOT_EMAIL=you@example.com"
  echo ""
}

parse_selection() {
  local raw="${1//[[:space:]]/}"
  RUN_JELLYFIN=0
  RUN_IMMICH=0
  RUN_TRANSMISSION=0
  RUN_NEXTCLOUD=0

  if [[ "$raw" == "0" ]]; then
    RUN_JELLYFIN=1
    RUN_IMMICH=1
    return 0
  fi

  local n
  IFS=',' read -ra nums <<< "$raw"
  for n in "${nums[@]}"; do
    case "$n" in
      0)
        RUN_JELLYFIN=1
        RUN_IMMICH=1
        return 0
        ;;
      1) RUN_JELLYFIN=1 ;;
      2) RUN_IMMICH=1 ;;
      3) RUN_TRANSMISSION=1 ;;
      4) RUN_NEXTCLOUD=1 ;;
      *)
        err "Invalid selection: ${n} (use 0–4, comma-separated)"
        exit 1
        ;;
    esac
  done

  if [[ "$RUN_JELLYFIN" -eq 0 && "$RUN_IMMICH" -eq 0 && "$RUN_TRANSMISSION" -eq 0 && "$RUN_NEXTCLOUD" -eq 0 ]]; then
    err "No services selected."
    exit 1
  fi
}

prompt_selection() {
  show_selection_menu
  local choice
  read -r -p "Enter choice [0]: " choice
  choice="${choice:-0}"
  parse_selection "$choice"
}

if [[ $# -eq 0 ]]; then
  if [[ -t 0 ]]; then
    prompt_selection
  else
    parse_selection "0"
  fi
elif [[ $# -eq 1 ]] && [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
elif [[ $# -eq 1 ]] && is_numeric_selection "$1"; then
  parse_selection "$1"
else
  err "Invalid argument(s). Use numbers only (e.g. 0, 1, 3, 4, 0,3, 1,4)."
  usage
  exit 1
fi

if [[ "$RUN_JELLYFIN" -eq 0 && "$RUN_IMMICH" -eq 0 && "$RUN_TRANSMISSION" -eq 0 && "$RUN_NEXTCLOUD" -eq 0 ]]; then
  err "No services selected."
  exit 1
fi

require_service() {
  local label="$1"
  local script="$2"
  local env_file="$3"
  if [[ ! -f "$script" ]]; then
    err "Missing ${label} deploy script: ${script}"
    exit 1
  fi
  if [[ ! -f "$env_file" ]]; then
    err "Missing ${label} .env — copy from .env.example: ${env_file}"
    exit 1
  fi
}

remove_legacy_media_containers() {
  local label="${1:-selfHosted}"
  shift
  local names=( "$@" )

  if [[ "${#names[@]}" -eq 0 ]]; then
    names=( jellyfin immich-server immich-machine-learning immich-redis immich-postgres )
  fi

  if ! command -v docker &>/dev/null; then
    return 0
  fi

  local removed=0 name
  for name in "${names[@]}"; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
      echo "[${label}] Removing legacy container: ${name}"
      docker rm -f "$name" 2>/dev/null || true
      removed=1
    fi
  done

  if [[ "$removed" -eq 1 ]]; then
    echo "[${label}] Legacy containers cleared."
  fi
}

stop_apeksha_media_compose() {
  if [[ ! -f "$APEKSHA_COMPOSE" || ! -f "$APEKSHA_ENV" ]]; then
    return 0
  fi

  local compose_cmd=""
  if docker compose version &>/dev/null 2>&1; then
    compose_cmd="docker compose"
  elif command -v docker-compose &>/dev/null; then
    compose_cmd="docker-compose"
  fi
  if [[ -z "$compose_cmd" ]]; then
    return 0
  fi

  (cd "$(dirname "$APEKSHA_COMPOSE")" && \
    $compose_cmd --env-file "$APEKSHA_ENV" rm -sf \
      jellyfin immich-server immich-machine-learning immich-redis immich-database 2>/dev/null) || true
}

deploy_jellyfin() {
  banner "Jellyfin"
  require_service "Jellyfin" "$JELLYFIN_DEPLOY" "${ROOT}/jellyfin/.env"

  local args=()
  if [[ "$DOCKER_ONLY" == "1" ]]; then
    args+=(--docker-only)
  fi

  step "Running ${JELLYFIN_DEPLOY}"
  bash "$JELLYFIN_DEPLOY" "${args[@]}"
  info "Jellyfin deploy finished."
}

deploy_immich() {
  banner "Immich"
  require_service "Immich" "$IMMICH_DEPLOY" "${ROOT}/immich/.env"

  local args=()
  if [[ "$DOCKER_ONLY" == "1" ]]; then
    args+=(--docker-only)
  fi

  step "Running ${IMMICH_DEPLOY}"
  bash "$IMMICH_DEPLOY" "${args[@]}"
  info "Immich deploy finished."
}

deploy_transmission() {
  banner "Transmission (system daemon)"
  if [[ ! -f "$TRANSMISSION_SCRIPT" ]]; then
    err "Missing Transmission script: ${TRANSMISSION_SCRIPT}"
    return 1
  fi
  if [[ ! -f "${ROOT}/jellyfin/.env" ]]; then
    err "Missing jellyfin/.env (defines MEDIA_PATH for downloads)"
    return 1
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    err "Transmission setup requires root: sudo bash ${ROOT}/deploy.sh 3"
    return 1
  fi

  step "Transmission (skipped if daemon already running and healthy)"
  bash "$TRANSMISSION_SCRIPT"
  info "Transmission deploy finished."
}

deploy_nextcloud() {
  banner "Nextcloud"
  require_service "Nextcloud" "$NEXTCLOUD_DEPLOY" "${ROOT}/nextcloud/.env"

  local args=()
  if [[ "$DOCKER_ONLY" == "1" ]]; then
    args+=(--docker-only)
  fi

  step "Running ${NEXTCLOUD_DEPLOY}"
  bash "$NEXTCLOUD_DEPLOY" "${args[@]}"
  info "Nextcloud deploy finished."
}

START_TS=$(date +%s)
FAILED=()

banner "selfHosted media deploy"
info "Services: Jellyfin=${RUN_JELLYFIN} Immich=${RUN_IMMICH} Transmission=${RUN_TRANSMISSION} Nextcloud=${RUN_NEXTCLOUD} dockerOnly=${DOCKER_ONLY}"
if [[ "$(id -u)" -eq 0 ]]; then
  info "Running as root"
else
  warn "Not root — nginx/certbot/transmission may be skipped. For full deploy: sudo bash ${ROOT}/deploy.sh"
fi

if [[ "$RUN_JELLYFIN" -eq 1 || "$RUN_IMMICH" -eq 1 ]]; then
  step "Clearing old Apeksha Jellyfin/Immich containers…"
  stop_apeksha_media_compose
  remove_legacy_media_containers "selfHosted"
  echo ""
fi

if [[ "$RUN_JELLYFIN" -eq 1 ]]; then
  deploy_jellyfin || FAILED+=("Jellyfin")
fi

if [[ "$RUN_IMMICH" -eq 1 ]]; then
  deploy_immich || FAILED+=("Immich")
fi

if [[ "$RUN_TRANSMISSION" -eq 1 ]]; then
  deploy_transmission || FAILED+=("Transmission")
fi

if [[ "$RUN_NEXTCLOUD" -eq 1 ]]; then
  deploy_nextcloud || FAILED+=("Nextcloud")
fi

ELAPSED=$(( $(date +%s) - START_TS ))
banner "Deploy summary (${ELAPSED}s)"

if [[ "${#FAILED[@]}" -eq 0 ]]; then
  info "All requested services deployed successfully."
else
  err "Failed: ${FAILED[*]}"
  exit 1
fi

cat <<'EOF'

Live URLs:
  Jellyfin:   https://streaming.thatinsaneguy.com
  Immich:     https://photos.thatinsaneguy.com
  Nextcloud:  https://kloud.thatinsaneguy.com

Useful commands:
  transmission-remote -l
  transmission-remote --session-info
  docker ps
  cd ~/Desktop/selfHosted/jellyfin && docker compose ps
  cd ~/Desktop/selfHosted/immich && docker compose ps
  cd ~/Desktop/selfHosted/nextcloud && docker compose ps
EOF
