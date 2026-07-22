#!/usr/bin/env bash
set -euo pipefail

awk_stage_codes='
{
  line = $0
  sub(/^[[:space:]]*-[[:space:]]*/, "", line)
  sub(/[[:space:]]*:.*/, "", line)
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)

  lowered = tolower($0)
  if (line != "" && ($0 ~ /搓玉|合成玉/ || lowered ~ /orundum/)) {
    orundum = line
  }
  if (line != "" && line ~ /^[A-Z]+-[0-9]+$/) {
    codes = codes " " line
    if (!fallback) fallback = line
  }
}
END {
  if (orundum != "") { print orundum; exit 0 }
  if (fallback) { print codes; exit 0 }
  exit 1
}
'

ROOT="/home/tian/ark"
DEPOT_CACHE="${ROOT}/depot_cache.json"
SELECT_SCRIPT="${ROOT}/scripts/select_stage_by_inventory.py"

input="$(cat)"

stage_info="$(printf '%s\n' "${input}" | awk "${awk_stage_codes}" 2>/dev/null)" || true

if [ -z "${stage_info}" ]; then
  exit 1
fi

if [ -f "${DEPOT_CACHE}" ] && command -v python3 >/dev/null 2>&1; then
  selected="$(printf '%s\n' "${stage_info}" | python3 "${SELECT_SCRIPT}" --depot-cache "${DEPOT_CACHE}" 2>/dev/null)" || true
  if [ -n "${selected}" ]; then
    printf '%s\n' "${selected}"
    exit 0
  fi
fi

printf '%s\n' "${stage_info}" | awk '{print $1; exit}'
