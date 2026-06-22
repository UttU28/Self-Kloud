#!/usr/bin/env bash
# Mount sdb at /mnt/chitragupt and lay out Jellyfin / Immich / Nextcloud storage.
#
#   sudo ./setup-chitragupt.sh mount       # fstab + folders (safe, no data touch)
#   sudo ./setup-chitragupt.sh copy        # COPY Desktop → chitragupt (originals kept)
#   sudo ./setup-chitragupt.sh switch      # point .env at chitragupt (after you verify copy)
#   sudo ./setup-chitragupt.sh nextcloud   # wire Jellyfin into Nextcloud UI
#   sudo ./setup-chitragupt.sh cleanup-old # DELETE old Desktop copies (interactive)
#   sudo ./setup-chitragupt.sh all         # mount + copy + switch + nextcloud (no delete)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP="${ROOT}"
CHITRAGUPT_UUID="6707d4b1-94cc-4a94-bbbd-eede82969001"
CHITRAGUPT_ROOT="/mnt/chitragupt"

real_user() {
  echo "${SUDO_USER:-${USER:-dedsec995}}"
}

old_desktop_paths() {
  echo \
    "${DESKTOP}/jellyfin/media" \
    "${DESKTOP}/jellyfin/config" \
    "${DESKTOP}/immich/library" \
    "${DESKTOP}/immich/postgres" \
    "${DESKTOP}/nextcloud/data" \
    "${DESKTOP}/nextcloud/db"
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()  { echo -e "${GREEN}[chitragupt]${NC} $*"; }
warn()  { echo -e "${YELLOW}[chitragupt]${NC} $*"; }
err()   { echo -e "${RED}[chitragupt]${NC} $*" >&2; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Run with sudo: sudo $0 $*"
    exit 1
  fi
}

run_as_user() {
  sudo -u "$(real_user)" bash -c "$*"
}

do_mount() {
  need_root mount
  info "Creating ${CHITRAGUPT_ROOT}…"
  mkdir -p "${CHITRAGUPT_ROOT}"

  if ! grep -q "${CHITRAGUPT_UUID}" /etc/fstab 2>/dev/null; then
    info "Adding fstab entry for Chitragupt (${CHITRAGUPT_UUID})…"
    cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    echo "UUID=${CHITRAGUPT_UUID}  ${CHITRAGUPT_ROOT}  ext4  defaults,nofail,x-systemd.device-timeout=10  0  2" >> /etc/fstab
  else
    info "fstab entry already present"
  fi

  # Drop udisks automount if active so fstab owns the mount
  local auto="/run/media/$(real_user)/${CHITRAGUPT_UUID}"
  if mountpoint -q "$auto" 2>/dev/null; then
    warn "Unmounting automount ${auto}…"
    umount "$auto" || true
  fi

  if ! mountpoint -q "${CHITRAGUPT_ROOT}"; then
    mount "${CHITRAGUPT_ROOT}"
  fi

  info "Disk mounted at ${CHITRAGUPT_ROOT} ($(df -h "${CHITRAGUPT_ROOT}" | awk 'NR==2 {print $2 " total, " $4 " free"}'))"

  local u="$(real_user)"
  info "Creating folder layout…"
  mkdir -p \
    "${CHITRAGUPT_ROOT}/jellyfin/config" \
    "${CHITRAGUPT_ROOT}/jellyfin/media/movies" \
    "${CHITRAGUPT_ROOT}/jellyfin/media/tv" \
    "${CHITRAGUPT_ROOT}/jellyfin/media/publicSpace" \
    "${CHITRAGUPT_ROOT}/jellyfin/media/.incomplete" \
    "${CHITRAGUPT_ROOT}/immich/library" \
    "${CHITRAGUPT_ROOT}/immich/postgres" \
    "${CHITRAGUPT_ROOT}/nextcloud/data" \
    "${CHITRAGUPT_ROOT}/nextcloud/db" \
    "${CHITRAGUPT_ROOT}/backups"

  chown -R "${u}:${u}" "${CHITRAGUPT_ROOT}/jellyfin" "${CHITRAGUPT_ROOT}/immich"
  chown -R 33:33 "${CHITRAGUPT_ROOT}/nextcloud"

  # Move loose backup zip if present at disk root
  if [[ -f "${CHITRAGUPT_ROOT}/supernovaBackup.zip" ]]; then
    warn "Moving supernovaBackup.zip → backups/"
    mv "${CHITRAGUPT_ROOT}/supernovaBackup.zip" "${CHITRAGUPT_ROOT}/backups/"
    chown "${u}:${u}" "${CHITRAGUPT_ROOT}/backups/supernovaBackup.zip"
  fi

  info "Layout ready:"
  find "${CHITRAGUPT_ROOT}" -maxdepth 3 -type d | sort | sed "s|^|  |"
}

stop_stack() {
  info "Stopping Jellyfin, Immich, Nextcloud containers…"
  for dir in jellyfin immich nextcloud; do
    if [[ -f "${DESKTOP}/${dir}/docker-compose.yml" ]]; then
      (cd "${DESKTOP}/${dir}" && docker compose --env-file .env down 2>/dev/null) || true
    fi
  done
}

rsync_if_needed() {
  local src="$1" dst="$2" label="$3"
  if [[ ! -d "$src" ]]; then
    warn "Skip ${label}: ${src} not found"
    return 0
  fi
  local count
  count="$(find "$src" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
  if [[ "$count" -eq 0 ]]; then
    info "Skip ${label}: ${src} is empty"
    return 0
  fi
  info "Copying ${label} (${src} → ${dst}) — originals on Desktop are NOT deleted…"
  mkdir -p "$dst"
  # Copy only: no --remove-source-files, no --delete
  rsync -aHAX --info=progress2 "${src}/" "${dst}/"
}

do_copy() {
  need_root copy
  info "Source: ${DESKTOP}"
  do_mount
  stop_stack

  local u="$(real_user)"

  rsync_if_needed \
    "${DESKTOP}/jellyfin/media" \
    "${CHITRAGUPT_ROOT}/jellyfin/media" \
    "Jellyfin media"

  if [[ -d "${DESKTOP}/jellyfin/config" ]] && [[ -n "$(ls -A "${DESKTOP}/jellyfin/config" 2>/dev/null)" ]]; then
    rsync_if_needed \
      "${DESKTOP}/jellyfin/config" \
      "${CHITRAGUPT_ROOT}/jellyfin/config" \
      "Jellyfin config"
  fi

  rsync_if_needed \
    "${DESKTOP}/immich/library" \
    "${CHITRAGUPT_ROOT}/immich/library" \
    "Immich library"

  rsync_if_needed \
    "${DESKTOP}/immich/postgres" \
    "${CHITRAGUPT_ROOT}/immich/postgres" \
    "Immich postgres"

  rsync_if_needed \
    "${DESKTOP}/nextcloud/data" \
    "${CHITRAGUPT_ROOT}/nextcloud/data" \
    "Nextcloud app data"

  rsync_if_needed \
    "${DESKTOP}/nextcloud/db" \
    "${CHITRAGUPT_ROOT}/nextcloud/db" \
    "Nextcloud MariaDB"

  chown -R "${u}:${u}" "${CHITRAGUPT_ROOT}/jellyfin" "${CHITRAGUPT_ROOT}/immich"
  chown -R 33:33 "${CHITRAGUPT_ROOT}/nextcloud"

  info "Copy finished. Desktop originals are still in place."
  echo ""
  echo "  1. Compare sizes:  du -sh ${CHITRAGUPT_ROOT}/*/*  and  du -sh ${DESKTOP}/*/*"
  echo "  2. When happy:     sudo $0 switch"
  echo "  3. Redeploy:       cd ${DESKTOP} && sudo ./deploy.sh"
  echo "  4. After testing:  sudo $0 cleanup-old"
}

do_switch() {
  need_root switch
  if ! mountpoint -q "${CHITRAGUPT_ROOT}"; then
    err "Mount ${CHITRAGUPT_ROOT} first: sudo $0 mount"
    exit 1
  fi

  info "Switching .env paths to ${CHITRAGUPT_ROOT} (does not delete Desktop copies)…"
  update_env_file "${DESKTOP}/jellyfin/.env" \
    "JELLYFIN_CONFIG_PATH=${CHITRAGUPT_ROOT}/jellyfin/config" \
    "MEDIA_PATH=${CHITRAGUPT_ROOT}/jellyfin/media"

  update_env_file "${DESKTOP}/immich/.env" \
    "IMMICH_UPLOAD_LOCATION=${CHITRAGUPT_ROOT}/immich/library" \
    "IMMICH_DB_DATA_LOCATION=${CHITRAGUPT_ROOT}/immich/postgres" \
    "IMMICH_PUBLIC_SPACE=${CHITRAGUPT_ROOT}/jellyfin/media/publicSpace"

  update_env_file "${DESKTOP}/nextcloud/.env" \
    "NEXTCLOUD_DATA_PATH=${CHITRAGUPT_ROOT}/nextcloud/data" \
    "NEXTCLOUD_DB_PATH=${CHITRAGUPT_ROOT}/nextcloud/db" \
    "CHITRAGUPT_ROOT=${CHITRAGUPT_ROOT}"

  info "Done. Redeploy so services use Chitragupt:"
  echo "  cd ${DESKTOP} && sudo ./deploy.sh"
  echo "  sudo ${DESKTOP}/jellyfin/applyTransmission.sh   # fix torrent download paths"
  if [[ -x "${DESKTOP}/jellyfin/applyTransmission.sh" ]]; then
    info "Applying Transmission paths now…"
    bash "${DESKTOP}/jellyfin/applyTransmission.sh" || warn "Transmission apply failed — run manually"
  fi
}

do_cleanup_old() {
  need_root cleanup-old
  OLD_DESKTOP_PATHS=( $(old_desktop_paths) )

  warn "This PERMANENTLY deletes old Desktop copies (after you copied to Chitragupt)."
  echo ""
  for path in "${OLD_DESKTOP_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
      du -sh "$path" 2>/dev/null | sed "s|^|  |" || echo "  ${path} (size unknown)"
    fi
  done
  echo ""
  read -r -p "Type DELETE to remove the paths above: " confirm
  if [[ "$confirm" != "DELETE" ]]; then
    info "Cancelled — nothing deleted."
    exit 0
  fi

  stop_stack

  for path in "${OLD_DESKTOP_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
      warn "Removing ${path}…"
      rm -rf "$path"
      mkdir -p "$path"
      info "  cleared ${path}"
    fi
  done

  info "Old Desktop data removed. Chitragupt copy is untouched at ${CHITRAGUPT_ROOT}."
  info "Redeploy if needed: cd ${DESKTOP} && sudo ./deploy.sh"
}

do_migrate() {
  # Back-compat: copy + switch, still never deletes Desktop data
  do_copy
  do_switch
}

update_env_file() {
  local file="$1"
  shift
  [[ -f "$file" ]] || { warn "Missing ${file}"; return; }
  for kv in "$@"; do
    local key="${kv%%=*}"
    local val="${kv#*=}"
    if grep -q "^${key}=" "$file"; then
      sed -i "s|^${key}=.*|${key}=${val}|" "$file"
    else
      echo "${key}=${val}" >> "$file"
    fi
  done
  info "  updated $(basename "$(dirname "$file")")/.env"
}

do_nextcloud() {
  need_root nextcloud
  if ! mountpoint -q "${CHITRAGUPT_ROOT}"; then
    do_mount
  fi

  if ! docker ps --format '{{.Names}}' | grep -qx nextcloud; then
    warn "Nextcloud container not running — start it first: cd ${DESKTOP}/nextcloud && sudo ./deploy.sh"
    return 1
  fi

  info "Enabling External storage app…"
  docker exec -u www-data nextcloud php occ app:enable files_external >/dev/null 2>&1 || true

  local user="${NEXTCLOUD_ADMIN_USER:-uttu}"
  if [[ -f "${DESKTOP}/nextcloud/.env" ]]; then
    # shellcheck disable=SC1091
    source "${DESKTOP}/nextcloud/.env"
    user="${NEXTCLOUD_ADMIN_USER:-uttu}"
  fi

  configure_external() {
    local name="$1" path="$2"
    if docker exec -u www-data nextcloud php occ files_external:list --all 2>/dev/null | grep -qF "$path"; then
      info "External storage already configured: ${name}"
      return 0
    fi
    info "Mounting ${name} in Nextcloud for user ${user}…"
    docker exec -u www-data nextcloud php occ files_external:create \
      "$name" local null::null \
      --user "$user" \
      -c "datadir=${path}" >/dev/null 2>&1 || true
  }

  configure_external "Jellyfin Media" "${JELLYFIN_MEDIA_PATH:-${CHITRAGUPT_ROOT}/jellyfin/media}"

  info "Scanning Jellyfin Media in Nextcloud…"
  docker exec -u www-data nextcloud php occ files:scan "$user" \
    --path="/${user}/files/Jellyfin Media" >/dev/null 2>&1 || true

  info "Nextcloud folders:"
  echo "  Files/          → your Google-Drive-style storage"
  echo "  Jellyfin Media/ → movies, tv, publicSpace"
}

usage() {
  cat <<EOF
Usage: sudo $0 {mount|copy|switch|nextcloud|cleanup-old|migrate|all}

  mount        Permanent mount at ${CHITRAGUPT_ROOT} + folder layout
  copy         COPY Desktop → Chitragupt (rsync; originals kept on Desktop)
  switch       Point .env at Chitragupt (run after verifying copy)
  nextcloud    Add Jellyfin as external folder in Nextcloud
  cleanup-old  DELETE old Desktop copies (interactive; type DELETE to confirm)
  migrate      copy + switch (still never deletes Desktop data)
  all          mount + copy + switch + nextcloud (no delete)

Recommended flow:
  sudo $0 mount && sudo $0 copy
  # verify Jellyfin / Immich / Nextcloud on Chitragupt
  sudo $0 switch && cd ${DESKTOP} && sudo ./deploy.sh
  sudo $0 nextcloud
  # when sure everything works:
  sudo $0 cleanup-old

Disk UUID: ${CHITRAGUPT_UUID} (447 GB ext4)
EOF
}

case "${1:-}" in
  mount)       do_mount ;;
  copy)        do_copy ;;
  switch)      do_switch ;;
  migrate)     do_migrate ;;
  nextcloud)   do_nextcloud ;;
  cleanup-old) do_cleanup_old ;;
  all)         do_mount; do_copy; do_switch; do_nextcloud ;;
  -h|--help|"") usage ;;
  *) err "Unknown command: $1"; usage; exit 1 ;;
esac
