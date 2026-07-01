#!/usr/bin/env bash
# bkp-chitragupt HDD — mount helper (source) + setup + daily mirror (run directly).
#
# Setup / use:
#   sudo ./bkp-chitragupt.sh mount     # format (if needed) + fstab + mount
#   sudo ./bkp-chitragupt.sh install   # install to /usr/local/sbin + daily 4 AM timer
#   sudo ./bkp-chitragupt.sh backup    # rsync mirror now
#   sudo ./bkp-chitragupt.sh all       # mount + install + first backup

BKP_HDD_PARTITION="${BKP_HDD_PARTITION:-/dev/sdc1}"
BKP_CHITRAGUPT_ROOT="${BKP_CHITRAGUPT_ROOT:-/mnt/bkp-chitragupt}"
CHITRAGUPT_ROOT="${CHITRAGUPT_ROOT:-/mnt/chitragupt}"
CHITRAGUPT_UUID="${CHITRAGUPT_UUID:-6707d4b1-94cc-4a94-bbbd-eede82969001}"
BKP_LOG="${BKP_LOG:-/var/log/bkp-chitragupt.log}"
BKP_LOCK="${BKP_LOCK:-/run/bkp-chitragupt.lock}"
BKP_INSTALLED="/usr/local/sbin/bkp-chitragupt.sh"
BKP_LIB_DIR="/usr/local/lib/selfHosted"
BKP_SYSTEMD_SERVICE="/etc/systemd/system/bkp-chitragupt.service"
BKP_SYSTEMD_TIMER="/etc/systemd/system/bkp-chitragupt.timer"

_bkp_info() { echo -e "\033[0;34m[bkp-chitragupt]\033[0m $*"; }
_bkp_ok()   { echo -e "\033[0;32m[bkp-chitragupt]\033[0m $*"; }
_bkp_warn() { echo -e "\033[1;33m[bkp-chitragupt]\033[0m $*"; }
_bkp_err()  { echo -e "\033[0;31m[bkp-chitragupt]\033[0m $*" >&2; }

_selfhosted_lib() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${dir}/chitragupt.sh" ]]; then
    echo "$dir"
  else
    echo "$BKP_LIB_DIR"
  fi
}

ensure_bkp_chitragupt_mounted() {
  local root="${BKP_CHITRAGUPT_ROOT}"
  local uuid="${BKP_CHITRAGUPT_UUID:-}"

  if mountpoint -q "$root" 2>/dev/null; then
    return 0
  fi

  _bkp_info "Disk not mounted at ${root} — attempting mount…"

  local mount_cmd=(mount)
  if [[ "$(id -u)" -ne 0 ]]; then
    if ! command -v sudo &>/dev/null; then
      _bkp_err "Need root to mount ${root}. Run: sudo mount ${root}"
      return 1
    fi
    mount_cmd=(sudo mount)
  fi

  if grep -qE "[[:space:]]${root//\//\\/}[[:space:]]" /etc/fstab 2>/dev/null; then
    "${mount_cmd[@]}" "$root" || true
  elif [[ -n "$uuid" ]] && grep -q "$uuid" /etc/fstab 2>/dev/null; then
    "${mount_cmd[@]}" "$root" || "${mount_cmd[@]}" "UUID=${uuid}" "$root" || true
  elif [[ -n "$uuid" && -e "/dev/disk/by-uuid/${uuid}" ]]; then
    mkdir -p "$root"
    "${mount_cmd[@]}" "UUID=${uuid}" "$root" || true
  else
    _bkp_err "No fstab entry for ${root}. Run: sudo ~/Desktop/selfHosted/bkp-chitragupt.sh mount"
    return 1
  fi

  if ! mountpoint -q "$root" 2>/dev/null; then
    _bkp_err "Failed to mount ${root}"
    return 1
  fi

  _bkp_ok "Mounted ${root}"
}

run_bkp_chitragupt_mirror() {
  local lib source dest
  lib="$(_selfhosted_lib)"

  # shellcheck disable=SC1091
  source "${lib}/chitragupt.sh"

  source="${CHITRAGUPT_ROOT}"
  dest="${BKP_CHITRAGUPT_ROOT}"

  exec 9>"$BKP_LOCK"
  if ! flock -n 9; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Backup already running, skipping." >>"$BKP_LOG"
    return 0
  fi

  log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" | tee -a "$BKP_LOG"
  }

  ensure_chitragupt_mounted force
  ensure_bkp_chitragupt_mounted

  log "Starting rsync: ${source}/ -> ${dest}/"

  rsync -aHAX --delete \
    --partial --partial-dir=.rsync-partial \
    --exclude='lost+found/' \
    --exclude='.Trash-*/' \
    --exclude='.cache/' \
    "${source}/" "${dest}/" >>"$BKP_LOG" 2>&1

  log "Backup finished successfully."
}

_bkp_main() {
  set -euo pipefail

  local ROOT
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  info() { _bkp_ok "$@"; }
  warn() { _bkp_warn "$@"; }
  err()  { _bkp_err "$@"; }

  need_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
      err "Run with sudo: sudo $0 $*"
      exit 1
    fi
  }

  do_mount() {
    need_root mount

    if [[ ! -b "$BKP_HDD_PARTITION" ]]; then
      err "${BKP_HDD_PARTITION} not found. Check with: lsblk"
      exit 1
    fi

    local fstype uuid
    fstype="$(blkid -s TYPE -o value "$BKP_HDD_PARTITION" 2>/dev/null || true)"

    if [[ "$fstype" != "ext4" ]]; then
      warn "Partition ${BKP_HDD_PARTITION} is ${fstype:-unformatted} (need ext4 for Linux mirror)."
      echo "WARNING: Formatting ERASES all data on ${BKP_HDD_PARTITION}."
      read -r -p "Type YES to format as ext4: " confirm
      if [[ "${confirm^^}" != "YES" ]]; then
        info "Aborted — nothing changed. (You must type YES in capitals.)"
        exit 0
      fi
      info "Formatting ${BKP_HDD_PARTITION} as ext4 (label: bkp-chitragupt)…"
      mkfs.ext4 -F -L bkp-chitragupt "$BKP_HDD_PARTITION"
    else
      info "${BKP_HDD_PARTITION} is already ext4 — keeping existing data."
    fi

    uuid="$(blkid -s UUID -o value "$BKP_HDD_PARTITION")"
    BKP_CHITRAGUPT_UUID="$uuid"
    info "Backup disk UUID: ${uuid}"

    mkdir -p "$BKP_CHITRAGUPT_ROOT"

    if grep -qE "[[:space:]]${BKP_CHITRAGUPT_ROOT//\//\\/}[[:space:]]" /etc/fstab 2>/dev/null; then
      info "fstab entry already present for ${BKP_CHITRAGUPT_ROOT}"
    else
      info "Adding fstab entry…"
      cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
      printf '\n# Mirror target for /mnt/chitragupt (HGST HDD)\nUUID=%s  %s  ext4  defaults,nofail,x-systemd.device-timeout=10  0  2\n' \
        "$uuid" "$BKP_CHITRAGUPT_ROOT" >>/etc/fstab
    fi

    if ! mountpoint -q "$BKP_CHITRAGUPT_ROOT"; then
      mount "$BKP_CHITRAGUPT_ROOT"
    fi

    info "Mounted ${BKP_CHITRAGUPT_ROOT} ($(df -h "${BKP_CHITRAGUPT_ROOT}" | awk 'NR==2 {print $2 " total, " $4 " free"}'))"

    if ! mountpoint -q "$CHITRAGUPT_ROOT"; then
      warn "Source ${CHITRAGUPT_ROOT} not mounted — mounting…"
      mkdir -p "$CHITRAGUPT_ROOT"
      if grep -q "$CHITRAGUPT_UUID" /etc/fstab 2>/dev/null; then
        mount "$CHITRAGUPT_ROOT" || mount "UUID=${CHITRAGUPT_UUID}" "$CHITRAGUPT_ROOT"
      else
        err "No fstab entry for ${CHITRAGUPT_ROOT}. Run: sudo ${ROOT}/chitragupt.sh mount"
        exit 1
      fi
    fi

    info "Source ${CHITRAGUPT_ROOT} ($(df -h "${CHITRAGUPT_ROOT}" | awk 'NR==2 {print $2 " total, " $3 " used, " $4 " free"}'))"
  }

  install_systemd_timer() {
    cat >"$BKP_SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Mirror ${CHITRAGUPT_ROOT} to ${BKP_CHITRAGUPT_ROOT}

[Service]
Type=oneshot
ExecStart=${BKP_INSTALLED} backup
EOF

    cat >"$BKP_SYSTEMD_TIMER" <<EOF
[Unit]
Description=Daily bkp-chitragupt mirror at 4:00 AM

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now bkp-chitragupt.timer
  }

  do_install() {
    need_root install

    mkdir -p "$BKP_LIB_DIR"
    install -m 644 "${ROOT}/chitragupt.sh" "$BKP_LIB_DIR/"
    install -m 755 "${ROOT}/bkp-chitragupt.sh" "$BKP_INSTALLED"

    touch "$BKP_LOG"
    chmod 644 "$BKP_LOG"

    install_systemd_timer

    info "Installed:"
    echo "  Chitragupt helper: ${BKP_LIB_DIR}/chitragupt.sh"
    echo "  Backup script:     ${BKP_INSTALLED}"
    echo "  Log:               ${BKP_LOG}"
    echo "  Schedule:          systemd timer daily at 4:00 AM (bkp-chitragupt.timer)"
    echo ""
    echo "  Check timer:  systemctl status bkp-chitragupt.timer"
    echo "  Next run:     systemctl list-timers bkp-chitragupt.timer"
  }

  do_backup() {
    need_root backup
    run_bkp_chitragupt_mirror
  }

  usage() {
    cat <<EOF
Usage: sudo $0 {mount|install|backup|all}

  mount    Format HDD as ext4 (if needed), fstab entry, mount ${BKP_CHITRAGUPT_ROOT}
  install  Copy scripts to /usr/local, enable systemd timer (4 AM daily)
  backup   Run rsync mirror now (${CHITRAGUPT_ROOT} -> ${BKP_CHITRAGUPT_ROOT})
  all      mount + install + backup

HDD partition: ${BKP_HDD_PARTITION} (edit BKP_HDD_PARTITION at top of this script if needed)
Source SSD:    ${CHITRAGUPT_ROOT} (UUID ${CHITRAGUPT_UUID})
Log:           ${BKP_LOG}
EOF
  }

  case "${1:-}" in
    mount)   do_mount ;;
    install) do_install ;;
    backup)  do_backup ;;
    all)     do_mount; do_install; do_backup ;;
    -h|--help|"") usage ;;
    *) err "Unknown command: $1"; usage; exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _bkp_main "$@"
fi
