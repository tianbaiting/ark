#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/tian/ark"
PROFILE_FILE="${ROOT}/maa-config/profiles/default.toml"
# [EN] Keep manual scans on the same device as scheduled automation. / [CN] 手动扫描与定时自动化统一使用同一台设备。
SERIAL="${1:-$(sed -n 's/^[[:space:]]*address[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${PROFILE_FILE}" | head -n1)}"
CACHE="${ROOT}/depot_cache.json"
LOG="${ROOT}/maa-cron.log"
ADB="${ADB:-/usr/bin/adb}"
PKG="com.hypergryph.arknights"

MAA_WIDTH=1080
MAA_HEIGHT=1920
MAA_DENSITY=480

timestamp() { date "+%F %T"; }

ORIG_WM_SIZE_OVERRIDE=""
ORIG_WM_DENSITY_OVERRIDE=""
SIZE_CHANGED=0
DENSITY_CHANGED=0
STAY_ON_ORIG=""
STAY_ON_CHANGED=0
POCKET_ORIG=""
POCKET_CHANGED=0

restore_display() {
  if [ "${POCKET_CHANGED}" -eq 1 ] && [ -n "${POCKET_ORIG}" ]; then
    ${ADB} -s "${SERIAL}" shell settings put system screen_off_pocket "${POCKET_ORIG}" >/dev/null 2>&1 || true
    echo "$(timestamp) scan_depot: restored screen_off_pocket=${POCKET_ORIG}" >>"${LOG}"
  fi
  if [ "${STAY_ON_CHANGED}" -eq 1 ] && [ -n "${STAY_ON_ORIG}" ]; then
    ${ADB} -s "${SERIAL}" shell settings put global stay_on_while_plugged_in "${STAY_ON_ORIG}" >/dev/null 2>&1 || true
    echo "$(timestamp) scan_depot: restored stay_on_while_plugged_in=${STAY_ON_ORIG}" >>"${LOG}"
  fi
  if [ "${DENSITY_CHANGED}" -eq 1 ]; then
    if [ -n "${ORIG_WM_DENSITY_OVERRIDE}" ]; then
      ${ADB} -s "${SERIAL}" shell wm density "${ORIG_WM_DENSITY_OVERRIDE}" >/dev/null 2>&1 || true
    else
      ${ADB} -s "${SERIAL}" shell wm density reset >/dev/null 2>&1 || true
    fi
    echo "$(timestamp) scan_depot: restored wm density" >>"${LOG}"
  fi
  if [ "${SIZE_CHANGED}" -eq 1 ]; then
    if [ -n "${ORIG_WM_SIZE_OVERRIDE}" ]; then
      ${ADB} -s "${SERIAL}" shell wm size "${ORIG_WM_SIZE_OVERRIDE}" >/dev/null 2>&1 || true
    else
      ${ADB} -s "${SERIAL}" shell wm size reset >/dev/null 2>&1 || true
    fi
    echo "$(timestamp) scan_depot: restored wm size" >>"${LOG}"
  fi
}

echo "$(timestamp) scan_depot: starting depot scan serial=${SERIAL}" >>"${LOG}"

# Save original overrides
wm_size_raw="$(${ADB} -s "${SERIAL}" shell wm size 2>/dev/null | tr -d '\r' || true)"
ORIG_WM_SIZE_OVERRIDE="$(printf "%s\n" "${wm_size_raw}" | sed -n 's/^Override size: //p' | head -n1)"
wm_density_raw="$(${ADB} -s "${SERIAL}" shell wm density 2>/dev/null | tr -d '\r' || true)"
ORIG_WM_DENSITY_OVERRIDE="$(printf "%s\n" "${wm_density_raw}" | sed -n 's/^Override density: //p' | head -n1)"

# Set resolution
${ADB} -s "${SERIAL}" shell wm size "${MAA_WIDTH}x${MAA_HEIGHT}" >/dev/null 2>&1 || true
SIZE_CHANGED=1
${ADB} -s "${SERIAL}" shell wm density "${MAA_DENSITY}" >/dev/null 2>&1 || true
DENSITY_CHANGED=1
echo "$(timestamp) scan_depot: set wm ${MAA_WIDTH}x${MAA_HEIGHT} density ${MAA_DENSITY}" >>"${LOG}"

# Keep screen on
STAY_ON_ORIG="$(${ADB} -s "${SERIAL}" shell settings get global stay_on_while_plugged_in 2>/dev/null | tr -d '\r' || true)"
if ! [[ "${STAY_ON_ORIG}" =~ ^[0-9]+$ ]]; then STAY_ON_ORIG="0"; fi
${ADB} -s "${SERIAL}" shell settings put global stay_on_while_plugged_in 3 >/dev/null 2>&1 || true
STAY_ON_CHANGED=1

# Disable Samsung pocket guard
POCKET_ORIG="$(${ADB} -s "${SERIAL}" shell settings get system screen_off_pocket 2>/dev/null | tr -d '\r' || true)"
if ! [[ "${POCKET_ORIG}" =~ ^[0-9]+$ ]]; then POCKET_ORIG="1"; fi
${ADB} -s "${SERIAL}" shell settings put system screen_off_pocket 0 >/dev/null 2>&1 || true
POCKET_CHANGED=1

# Wake and unlock
${ADB} -s "${SERIAL}" shell input keyevent 224 >/dev/null 2>&1 || true
${ADB} -s "${SERIAL}" shell input keyevent 82 >/dev/null 2>&1 || true
${ADB} -s "${SERIAL}" shell input swipe 540 1600 540 400 300 >/dev/null 2>&1 || true

# Kill and restart game at the new resolution
${ADB} -s "${SERIAL}" shell am force-stop "${PKG}" >/dev/null 2>&1 || true
sleep 2
${ADB} -s "${SERIAL}" shell monkey -p "${PKG}" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
echo "$(timestamp) scan_depot: game restarted, waiting 60s for load..." >>"${LOG}"
sleep 60

raw_output="${TMPDIR:-/tmp}/maa_depot_output_$$.txt"

cleanup() {
  rm -f "${raw_output}"
  restore_display
}
trap cleanup EXIT

set +e
timeout --signal=INT --kill-after=30s 30m \
  ${DOCKER:-docker} compose run --rm maa maa run depot -a "${SERIAL}" --batch \
  -v \
  >"${raw_output}" 2>&1
rc=$?
set -e

cat "${raw_output}" >>"${LOG}"

if [ "${rc}" -ne 0 ]; then
  echo "$(timestamp) scan_depot: maa run depot failed rc=${rc}" >>"${LOG}"
  exit "${rc}"
fi

if ! python3 "${ROOT}/scripts/extract_maa_inventory.py" depot "${raw_output}" "${CACHE}" 2>>"${LOG}"; then
  echo "$(timestamp) scan_depot: failed to parse depot data from output" >>"${LOG}"
  exit 1
fi

echo "$(timestamp) scan_depot: done" >>"${LOG}"
