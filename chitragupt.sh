#!/usr/bin/env bash
# Shared Chitragupt disk helpers — source from deploy scripts.
#
#   source "${SELFHOSTED_ROOT}/chitragupt.sh"
#   ensure_chitragupt_mounted

_chitragupt_info() { echo -e "\033[0;34m[chitragupt]\033[0m $*"; }
_chitragupt_ok()   { echo -e "\033[0;32m[chitragupt]\033[0m $*"; }
_chitragupt_warn() { echo -e "\033[1;33m[chitragupt]\033[0m $*"; }
_chitragupt_err()  { echo -e "\033[0;31m[chitragupt]\033[0m $*" >&2; }

# Returns 0 if any supplied path lives under CHITRAGUPT_ROOT.
_uses_chitragupt_paths() {
  local root="${CHITRAGUPT_ROOT:-/mnt/chitragupt}"
  local p
  for p in "$@"; do
    [[ -n "$p" && "$p" == "${root}"* ]] && return 0
  done
  return 1
}

# Mount CHITRAGUPT_ROOT if fstab entry exists but disk is not mounted yet.
ensure_chitragupt_mounted() {
  local root="${CHITRAGUPT_ROOT:-/mnt/chitragupt}"
  local uuid="${CHITRAGUPT_UUID:-}"

  if ! _uses_chitragupt_paths \
    "${NEXTCLOUD_DATA_PATH:-}" \
    "${NEXTCLOUD_DB_PATH:-}" \
    "${JELLYFIN_MEDIA_PATH:-}" \
    "${IMMICH_LIBRARY_PATH:-}" \
    "${MEDIA_PATH:-}" \
    "${JELLYFIN_CONFIG_PATH:-}" \
    "${IMMICH_UPLOAD_LOCATION:-}" \
    "${IMMICH_DB_DATA_LOCATION:-}"; then
    return 0
  fi

  if mountpoint -q "$root" 2>/dev/null; then
    return 0
  fi

  _chitragupt_info "Disk not mounted at ${root} — attempting mount…"

  local mount_cmd=(mount)
  if [[ "$(id -u)" -ne 0 ]]; then
    if ! command -v sudo &>/dev/null; then
      _chitragupt_err "Need root to mount ${root}. Run: sudo mount ${root}"
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
    _chitragupt_err "No fstab entry for ${root}. Run: sudo ~/Desktop/selfHosted/setup-chitragupt.sh mount"
    return 1
  fi

  if ! mountpoint -q "$root" 2>/dev/null; then
    _chitragupt_err "Failed to mount ${root}"
    return 1
  fi

  _chitragupt_ok "Mounted ${root}"
}

# Warn (non-fatal) when optional bind-mount source dirs are missing.
warn_chitragupt_bind_paths() {
  local label path
  while [[ $# -ge 2 ]]; do
    label="$1"
    path="$2"
    shift 2
    if [[ -n "$path" && ! -d "$path" ]]; then
      _chitragupt_warn "${label} path missing: ${path}"
    fi
  done
}
