#!/usr/bin/env bash
# Move finished Transmission downloads into their library folder (movies / tv /
# parvatiNambyar). Skips .incomplete/. Uses Apeksha backend logic + Transmission RPC.
#
#   ./relocateCompletedTorrents.sh
#
# Prefer the Apeksha UI "Move completed" button (POST /roddent/relocate-completed).

set -euo pipefail

jellyfinDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
apekshaBackend="$(cd "${jellyfinDir}/../../Apeksha/backend" && pwd)"

if [[ ! -d "$apekshaBackend" ]]; then
  echo "Apeksha backend not found at ${apekshaBackend}" >&2
  exit 1
fi

if [[ -f "${jellyfinDir}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${jellyfinDir}/.env"
  set +a
fi

export RODDENT_MEDIA_ROOT="${MEDIA_PATH:-${RODDENT_MEDIA_ROOT:-}}"

cd "$apekshaBackend"
exec python3 - <<'PY'
import json
import sys

from utils.roddent import relocateCompletedRoddenTransmissionApi

result = relocateCompletedRoddenTransmissionApi()
print(json.dumps(result, indent=2))
sys.exit(0 if result.get("ok") else 1)
PY