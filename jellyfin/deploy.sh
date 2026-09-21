#!/usr/bin/env bash
# Jellyfin deploy — Docker + nginx (streaming.thatinsaneguy.com)
#
#   ./deploy.sh
#   ./deploy.sh --docker-only
#   ./deploy.sh --rebuild-image       # force rebuild even if forks are unchanged
#   sudo ./deploy.sh
#   sudo ./deploy.sh --transmission   # also configure transmission-daemon for media/
#
# Custom image (default): fetch uttu28 forks on JELLYFIN_FORK_BRANCH and rebuild
# only when origin SHAs differ from the last successful build (.built-from).

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
REBUILD_IMAGE=0

for arg in "$@"; do
  case "$arg" in
    --docker-only) DOCKER_ONLY=1 ;;
    --transmission) RUN_TRANSMISSION=1 ;;
    --rebuild-image) REBUILD_IMAGE=1 ;;
    -h|--help)
      echo "Usage: $0 [--docker-only] [--transmission] [--rebuild-image]"
      echo "  --transmission    Configure system transmission-daemon (requires sudo)"
      echo "  --rebuild-image   Force rebuild the custom image even if forks are unchanged"
      echo "  (default custom)  Fetch forks and rebuild only when origin commits changed"
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
  export JELLYFIN_IMAGE_SOURCE="${JELLYFIN_IMAGE_SOURCE:-custom}"
  export JELLYFIN_IMAGE="${JELLYFIN_IMAGE:-jellyfin/jellyfin:hide-items-amd64}"
  export JELLYFIN_FORK_SERVER="${JELLYFIN_FORK_SERVER:-https://github.com/uttu28/jellyfin.git}"
  export JELLYFIN_FORK_WEB="${JELLYFIN_FORK_WEB:-https://github.com/uttu28/jellyfin-web.git}"
  export JELLYFIN_FORK_BRANCH="${JELLYFIN_FORK_BRANCH:-feature/hide-items-from-library}"
  export JELLYFIN_PACKAGING_DIR="${JELLYFIN_PACKAGING_DIR:-${JELLYFIN_DIR}/../jellyfin-packaging}"
}

checkNvidiaContainerToolkit() {
  if [ "${JELLYFIN_GPU:-nvidia}" = "none" ]; then
    return 0
  fi
  if ! command -v nvidia-smi &>/dev/null; then
    printWarning "nvidia-smi not found — GPU transcoding will not work."
    return 0
  fi
  if ! docker info 2>/dev/null | grep -qi nvidia; then
    printWarning "Docker NVIDIA runtime not configured."
    printWarning "Install and configure, then restart Docker:"
    echo "  sudo pacman -S nvidia-container-toolkit"
    echo "  sudo nvidia-ctk runtime configure --runtime=docker"
    echo "  sudo systemctl restart docker"
    return 1
  fi
  printStatus "NVIDIA Container Toolkit detected for Docker."
}

configureGpuEncoding() {
  local enc="${JELLYFIN_CONFIG_PATH}/config/encoding.xml"

  if [ "${JELLYFIN_GPU:-nvidia}" = "none" ]; then
    printWarning "JELLYFIN_GPU=none — leaving encoding.xml unchanged."
    return 0
  fi
  if ! command -v nvidia-smi &>/dev/null; then
    printWarning "nvidia-smi not found — skipping encoding.xml GPU settings."
    return 0
  fi
  if [ ! -f "$enc" ]; then
    printWarning "No encoding.xml yet — enable NVENC in Dashboard → Playback after first start."
    return 0
  fi

  printStep "Configuring Jellyfin encoding.xml for NVIDIA NVENC…"
  cp -a "$enc" "${enc}.bak.$(date +%Y%m%d%H%M%S)"

  sed -i \
    -e 's|<HardwareAccelerationType>none</HardwareAccelerationType>|<HardwareAccelerationType>nvenc</HardwareAccelerationType>|g' \
    -e 's|<EnableTonemapping>false</EnableTonemapping>|<EnableTonemapping>true</EnableTonemapping>|g' \
    "$enc"

  if ! grep -q '<string>hevc</string>' "$enc"; then
    sed -i '/<string>h264<\/string>/a\    <string>hevc</string>' "$enc"
  fi
  if ! grep -q '<string>vp9</string>' "$enc"; then
    sed -i '/<string>hevc<\/string>/a\    <string>vp9</string>' "$enc" 2>/dev/null \
      || sed -i '/<string>h264<\/string>/a\    <string>vp9</string>' "$enc"
  fi
  if ! grep -q '<string>mpeg2video</string>' "$enc"; then
    sed -i '/<string>vc1<\/string>/a\    <string>mpeg2video</string>' "$enc"
  fi

  printStatus "encoding.xml → HardwareAccelerationType=nvenc, tonemapping=on"
}

# Custom image = jellyfin-packaging Docker build with server/web remotes pointed at uttu28.
# Official image = docker compose pull of jellyfin/jellyfin:latest (stable Hub).
packagingOwner() {
  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    echo "${SUDO_USER}"
  else
    echo "${JELLYFIN_PACKAGING_OWNER:-dedsec995}"
  fi
}

chownPackagingForks() {
  local pack="${JELLYFIN_PACKAGING_DIR}"
  local owner
  owner="$(packagingOwner)"
  if [ "$(id -u)" -eq 0 ]; then
    printStep "chown ${owner} on packaging forks (docker build leaves root-owned files)…"
    chown -R "${owner}:${owner}" "${pack}/jellyfin-server" "${pack}/jellyfin-web"
  fi
}

imageStampPath() {
  echo "${JELLYFIN_DIR}/.built-from"
}

stampValue() {
  local key="$1"
  local file="$2"
  awk -F= -v k="$key" '$1==k {print $2; exit}' "$file"
}

writeImageStamp() {
  local pack="${JELLYFIN_PACKAGING_DIR}"
  local stamp
  stamp="$(imageStampPath)"
  cat >"$stamp" <<EOF
IMAGE=${JELLYFIN_IMAGE}
BRANCH=${JELLYFIN_FORK_BRANCH}
SERVER_REMOTE=${JELLYFIN_FORK_SERVER}
WEB_REMOTE=${JELLYFIN_FORK_WEB}
SERVER_SHA=$(git -C "${pack}/jellyfin-server" rev-parse HEAD)
WEB_SHA=$(git -C "${pack}/jellyfin-web" rev-parse HEAD)
EOF
}

fetchForkTip() {
  local dir="$1"
  local url="$2"
  local branch="$3"
  if [ ! -e "${dir}/.git" ]; then
    printError "Missing git checkout: ${dir}"
    return 1
  fi
  git -C "$dir" remote set-url origin "$url" || return 1
  git -C "$dir" fetch origin "$branch" || return 1
  git -C "$dir" rev-parse "origin/${branch}"
}

checkoutFork() {
  local dir="$1"
  local url="$2"
  local branch="$3"
  local head expected
  # Submodules use a .git *file* (gitdir pointer), not a directory.
  if [ ! -e "${dir}/.git" ]; then
    printError "Missing git checkout: ${dir}"
    return 1
  fi
  git -C "$dir" remote set-url origin "$url" || return 1
  git -C "$dir" fetch origin "$branch" || return 1
  # Packaging checkouts are disposable. Docker/chown can leave dirty files that
  # block `checkout -B` if we reset only after switching.
  git -C "$dir" reset --hard HEAD >/dev/null 2>&1 || true
  git -C "$dir" clean -fd >/dev/null 2>&1 || true
  git -C "$dir" checkout -f -B "$branch" "origin/${branch}" || return 1
  git -C "$dir" reset --hard "origin/${branch}" || return 1
  git -C "$dir" clean -fd || return 1
  head="$(git -C "$dir" rev-parse HEAD)"
  expected="$(git -C "$dir" rev-parse "origin/${branch}")"
  if [ "$head" != "$expected" ]; then
    printError "${dir} HEAD ${head} != origin/${branch} ${expected}"
    return 1
  fi
  if [ -n "$(git -C "$dir" status --porcelain)" ]; then
    printError "Working tree not clean after checkout: ${dir}"
    git -C "$dir" status -sb
    return 1
  fi
  printStatus "$(basename "$dir") @ ${head:0:12} (${branch})"
}

ensurePackagingCheckout() {
  local pack="${JELLYFIN_PACKAGING_DIR}"
  local selfhosted_root
  selfhosted_root="$(cd "${JELLYFIN_DIR}/.." && pwd)"

  # Empty dir after `git clone` without --recurse-submodules
  # jellyfin-packaging itself may be a submodule (.git file).
  if [ ! -e "${pack}/.git" ]; then
    if [ -f "${selfhosted_root}/.gitmodules" ] && [ -e "${selfhosted_root}/.git" ]; then
      printStep "Initializing jellyfin-packaging submodule…"
      git -C "$selfhosted_root" submodule update --init jellyfin-packaging
    fi
  fi
  if [ ! -e "${pack}/.git" ]; then
    printStep "Cloning jellyfin-packaging…"
    if [ -d "$pack" ] && [ -z "$(ls -A "$pack" 2>/dev/null)" ]; then
      rmdir "$pack"
    fi
    git clone https://github.com/jellyfin/jellyfin-packaging.git "$pack"
  fi

  # Only init missing server/web checkouts. `submodule update` every rebuild
  # resets them to packaging's pinned official commits and undoes the forks.
  if [ ! -e "${pack}/jellyfin-server/.git" ] || [ ! -e "${pack}/jellyfin-web/.git" ]; then
    printStep "Initializing packaging submodules (missing server/web checkout)…"
    git -C "$pack" submodule update --init
  fi
  chownPackagingForks
}

syncForksToOrigin() {
  local pack="${JELLYFIN_PACKAGING_DIR}"
  checkoutFork "${pack}/jellyfin-server" "${JELLYFIN_FORK_SERVER}" "${JELLYFIN_FORK_BRANCH}" || return 1
  checkoutFork "${pack}/jellyfin-web" "${JELLYFIN_FORK_WEB}" "${JELLYFIN_FORK_BRANCH}" || return 1
}

customImageNeedsRebuild() {
  local pack="${JELLYFIN_PACKAGING_DIR}"
  local img="${JELLYFIN_IMAGE}"
  local stamp server_tip web_tip

  if [ "$REBUILD_IMAGE" -eq 1 ]; then
    printStep "Forced rebuild (--rebuild-image)"
    return 0
  fi
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    printStep "Image ${img} is missing — will build"
    return 0
  fi

  stamp="$(imageStampPath)"
  printStep "Fetching forks (${JELLYFIN_FORK_BRANCH})…"
  server_tip="$(fetchForkTip "${pack}/jellyfin-server" "${JELLYFIN_FORK_SERVER}" "${JELLYFIN_FORK_BRANCH}")" || return 2
  web_tip="$(fetchForkTip "${pack}/jellyfin-web" "${JELLYFIN_FORK_WEB}" "${JELLYFIN_FORK_BRANCH}")" || return 2

  if [ ! -f "$stamp" ]; then
    local local_server local_web
    local_server="$(git -C "${pack}/jellyfin-server" rev-parse HEAD)"
    local_web="$(git -C "${pack}/jellyfin-web" rev-parse HEAD)"
    if [ "$local_server" = "$server_tip" ] && [ "$local_web" = "$web_tip" ]; then
      writeImageStamp
      printStatus "No prior stamp; local forks already match origin — skipping rebuild"
      return 1
    fi
    printStep "No prior stamp and origin has newer commits — will rebuild"
    return 0
  fi

  if [ "$(stampValue IMAGE "$stamp")" != "$img" ] \
    || [ "$(stampValue BRANCH "$stamp")" != "${JELLYFIN_FORK_BRANCH}" ] \
    || [ "$(stampValue SERVER_REMOTE "$stamp")" != "${JELLYFIN_FORK_SERVER}" ] \
    || [ "$(stampValue WEB_REMOTE "$stamp")" != "${JELLYFIN_FORK_WEB}" ] \
    || [ "$(stampValue SERVER_SHA "$stamp")" != "$server_tip" ] \
    || [ "$(stampValue WEB_SHA "$stamp")" != "$web_tip" ]; then
    printStep "Forks or image config changed — will rebuild"
    printStatus "server ${server_tip:0:12}  web ${web_tip:0:12}"
    return 0
  fi

  printStatus "Forks unchanged (server ${server_tip:0:12}, web ${web_tip:0:12}) — skipping image rebuild"
  return 1
}

ensureBuildPythonDeps() {
  if ! command -v python3 &>/dev/null; then
    printError "python3 is required to run jellyfin-packaging/build.py"
    return 1
  fi
  if python3 -c "import git, yaml, packaging.version" 2>/dev/null; then
    return 0
  fi
  if [ "$(id -u)" -eq 0 ] && command -v pacman &>/dev/null; then
    printStep "Installing python-gitpython python-yaml python-packaging…"
    pacman -S --needed --noconfirm python-gitpython python-yaml python-packaging || return 1
    if python3 -c "import git, yaml, packaging.version" 2>/dev/null; then
      return 0
    fi
  fi
  printError "build.py needs GitPython, PyYAML, and packaging."
  printError "Arch: sudo pacman -S python-gitpython python-yaml python-packaging"
  return 1
}

patchPackagingForLocalDockerBuild() {
  local py="${JELLYFIN_PACKAGING_DIR}/build.py"
  local df="${JELLYFIN_PACKAGING_DIR}/docker/Dockerfile"
  if [ ! -f "$py" ]; then
    return 0
  fi
  # Upstream CI uses --no-cache. Local fork rebuilds should reuse layers and
  # inherit host DNS — Debian slim in BuildKit often cannot resolve
  # repo.jellyfin.org (curl: 6) otherwise.
  if grep -q 'docker buildx build --progress=plain --no-cache' "$py"; then
    printStep "Local Docker build: host network + layer cache"
    sed -i 's/docker buildx build --progress=plain --no-cache/docker buildx build --progress=plain --network=host/' "$py"
  fi
  if [ -f "$df" ] && grep -q 'curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key' "$df"; then
    sed -i 's|curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key|curl -fsSL --retry 8 --retry-all-errors --retry-delay 3 https://repo.jellyfin.org/jellyfin_team.gpg.key|' "$df"
  fi
}

ensureCustomImage() {
  local pack="${JELLYFIN_PACKAGING_DIR}"
  local img="${JELLYFIN_IMAGE}"
  local arch="amd64"
  local version="${img##*:}"
  version="${version%-${arch}}"

  local need=0
  ensurePackagingCheckout || return 1

  customImageNeedsRebuild && need=0 || need=$?
  if [ "$need" -eq 1 ]; then
    return 0
  fi
  if [ "$need" -ne 0 ]; then
    if docker image inspect "$img" >/dev/null 2>&1; then
      printWarning "Could not fetch forks — keeping existing ${img}"
      return 0
    fi
    printError "Could not fetch forks and ${img} is missing"
    return 1
  fi

  ensureBuildPythonDeps || return 1
  syncForksToOrigin || return 1
  patchPackagingForLocalDockerBuild

  printStep "Building ${img} from forks (${JELLYFIN_FORK_BRANCH})…"
  local attempt=1
  local max_attempts=3
  while true; do
    if (
      cd "$pack"
      python3 ./build.py "$version" docker "$arch" --local
    ); then
      break
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      printError "build.py failed after ${max_attempts} attempts (often Docker DNS: repo.jellyfin.org)."
      chownPackagingForks
      return 1
    fi
    printWarning "Docker image build failed (attempt ${attempt}/${max_attempts}) — retrying in 15s…"
    attempt=$((attempt + 1))
    sleep 15
  done
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    printError "Build finished but image ${img} was not found."
    chownPackagingForks
    return 1
  fi
  writeImageStamp
  chownPackagingForks
  printStatus "Built ${img}"
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

  mkdir -p "${MEDIA_PATH}/0movies" "${MEDIA_PATH}/tv" "${MEDIA_PATH}/parvatiNambyar" "${JELLYFIN_CONFIG_PATH}"
  ensure_chitragupt_mounted || exit 1
  fixConfigOwnership
  configureGpuEncoding
  checkNvidiaContainerToolkit || printWarning "Continuing without confirmed NVIDIA Docker runtime."

  cd "$JELLYFIN_DIR"
  if [ "${JELLYFIN_IMAGE_SOURCE}" = "official" ]; then
    # Official practice: pull jellyfin/jellyfin:latest from Docker Hub (stable).
    export JELLYFIN_IMAGE="jellyfin/jellyfin:latest"
    printStep "Pulling official image ${JELLYFIN_IMAGE}…"
    $compose_cmd --env-file .env pull jellyfin
  else
    # Custom: do not pull. Hub has no hide-items-amd64 tag; pull would fail or overwrite.
    # $compose_cmd --env-file .env pull jellyfin
    local custom_ok=1
    if ! ensureCustomImage; then
      printError "Custom image rebuild failed."
      if docker image inspect "${JELLYFIN_IMAGE}" >/dev/null 2>&1; then
        printWarning "Starting existing ${JELLYFIN_IMAGE} so streaming stays up."
        custom_ok=0
      else
        return 1
      fi
    fi
  fi
  $compose_cmd --env-file .env up -d --force-recreate
  printStatus "Jellyfin started on 127.0.0.1:8096 (${JELLYFIN_IMAGE})"
  if [ "${custom_ok:-1}" -eq 0 ]; then
    return 1
  fi

  if [ "${JELLYFIN_GPU:-nvidia}" != "none" ] && command -v nvidia-smi &>/dev/null; then
    sleep 3
    if docker exec jellyfin nvidia-smi &>/dev/null; then
      printStatus "GPU visible inside Jellyfin container (NVENC ready)."
    else
      printWarning "GPU not visible inside container — finish NVIDIA toolkit setup and redeploy."
    fi
  fi
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
