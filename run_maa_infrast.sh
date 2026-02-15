#!/usr/bin/env bash
set -euo pipefail

# Project-local runtime settings.
ROOT="/home/tian/ark"
ADB_SERIAL="RF8N316396H"
ADB="/usr/bin/adb"
DOCKER="/usr/bin/docker"
LOG="${ROOT}/maa-cron.log"
FAILED=0
LOCK_FILE="/tmp/run_maa_infrast.lock"
# Use POSIX TZ format because container may not have /usr/share/zoneinfo.
# UTC-8 means UTC+08:00 (CN time). If needed, override when launching:
# MAA_TZ=UTC-9 bash ./run_maa_infrast.sh
MAA_TZ="${MAA_TZ:-UTC-8}"
INFRAST_PLAN_FILE="243_4times_tbt20251104_noskip.json"
PLAN_SRC="${ROOT}/${INFRAST_PLAN_FILE}"
PLAN_DST="${ROOT}/maa-config/infrast/${INFRAST_PLAN_FILE}"
INFRAST_TASK_NAME="infrast"
FALLBACK_INFRAST_TASK_NAME="infrast_default"
ORIG_STAY_ON="0"
TEMP_STAY_ON_SET=0
SLEEP_SCREEN_ON_EXIT=0

cd "${ROOT}"

timestamp() {
  date "+%F %T"
}

# Restore temporary display settings on any exit path.
cleanup() {
  local rc=$?
  trap - EXIT

  if [ "${TEMP_STAY_ON_SET}" -eq 1 ]; then
    ${ADB} -s "${ADB_SERIAL}" shell settings put global stay_on_while_plugged_in "${ORIG_STAY_ON}" >/dev/null 2>&1 || true
    echo "$(timestamp) restored stay_on_while_plugged_in=${ORIG_STAY_ON}" >>"${LOG}"
  fi

  if [ "${SLEEP_SCREEN_ON_EXIT}" -eq 1 ]; then
    ${ADB} -s "${ADB_SERIAL}" shell input keyevent 223 >/dev/null 2>&1 || true
    echo "$(timestamp) requested screen sleep on exit" >>"${LOG}"
  fi

  exit "${rc}"
}

trap cleanup EXIT

# Prevent overlapping runs from cron/manual execution.
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "$(timestamp) another run is active, skip this run" >>"${LOG}"
  exit 0
fi

# Run one step, always log start/end, optionally fail-fast.
run_step() {
  local name="$1"
  local fatal="$2"
  shift 2

  echo "$(timestamp) ${name} start" >>"${LOG}"
  set +e
  "$@" >>"${LOG}" 2>&1
  local rc=$?
  set -e
  echo "$(timestamp) ${name} end rc=${rc}" >>"${LOG}"

  if [ "${rc}" -ne 0 ]; then
    FAILED=1
    if [ "${fatal}" -eq 1 ]; then
      exit "${rc}"
    fi
  fi
}

# Run maa-cli in container with fixed timezone to keep infrast period matching the plan.
run_maa() {
  ${DOCKER} compose run --rm -e TZ="${MAA_TZ}" maa maa "$@"
}

# Validate that the effective infrast task really points to the expected custom shift file.
verify_infrast_plan() {
  local expected="/root/.config/maa/infrast/${INFRAST_PLAN_FILE}"
  local output=""
  local rc=0

  set +e
  output="$(run_maa run infrast -a "${ADB_SERIAL}" --batch --dry-run -vv 2>&1)"
  rc=$?
  set -e

  printf "%s\n" "${output}" >>"${LOG}"
  if [ "${rc}" -ne 0 ]; then
    echo "$(timestamp) infrast plan verify failed: dry-run rc=${rc}" >>"${LOG}"
    return 1
  fi

  if ! grep -Fq "\"filename\": \"${expected}\"" <<<"${output}"; then
    echo "$(timestamp) infrast plan verify failed: expected ${expected}" >>"${LOG}"
    return 1
  fi

  echo "$(timestamp) infrast plan verify ok: ${expected}" >>"${LOG}"
  return 0
}

select_infrast_task() {
  local fallback_task="${ROOT}/maa-config/tasks/${FALLBACK_INFRAST_TASK_NAME}.json"

  echo "$(timestamp) maa infrast config verify start" >>"${LOG}"
  if verify_infrast_plan; then
    INFRAST_TASK_NAME="infrast"
    echo "$(timestamp) maa infrast config verify end rc=0 use=${INFRAST_TASK_NAME}" >>"${LOG}"
    return 0
  fi

  if [ -f "${fallback_task}" ]; then
    INFRAST_TASK_NAME="${FALLBACK_INFRAST_TASK_NAME}"
    echo "$(timestamp) maa infrast config verify end rc=0 fallback=${INFRAST_TASK_NAME}" >>"${LOG}"
  else
    INFRAST_TASK_NAME="infrast"
    echo "$(timestamp) maa infrast fallback task missing: ${fallback_task}, keep use=${INFRAST_TASK_NAME}" >>"${LOG}"
  fi
  return 0
}

# Make sure adb daemon is ready.
${ADB} start-server >/dev/null 2>&1 || true

state="$(${ADB} -s "${ADB_SERIAL}" get-state 2>/dev/null || true)"
if [ "${state}" != "device" ]; then
  echo "$(timestamp) adb device not ready: ${state:-none}" >>"${LOG}"
  exit 1
fi

# Normalize display and keep screen awake to reduce OCR/interaction failures.
${ADB} -s "${ADB_SERIAL}" shell wm size 1080x1920 >/dev/null 2>&1 || true
${ADB} -s "${ADB_SERIAL}" shell wm density 480 >/dev/null 2>&1 || true

# Keep screen awake only during this run, then restore original value in cleanup().
ORIG_STAY_ON="$(${ADB} -s "${ADB_SERIAL}" shell settings get global stay_on_while_plugged_in 2>/dev/null | tr -d '\r' || true)"
if ! [[ "${ORIG_STAY_ON}" =~ ^[0-9]+$ ]]; then
  ORIG_STAY_ON="0"
fi
${ADB} -s "${ADB_SERIAL}" shell settings put global stay_on_while_plugged_in 3 >/dev/null 2>&1 || true
TEMP_STAY_ON_SET=1
SLEEP_SCREEN_ON_EXIT=1

${ADB} -s "${ADB_SERIAL}" shell input keyevent 224 >/dev/null 2>&1 || true
${ADB} -s "${ADB_SERIAL}" shell input keyevent 82 >/dev/null 2>&1 || true
${ADB} -s "${ADB_SERIAL}" shell input swipe 540 1600 540 400 300 >/dev/null 2>&1 || true

# Ensure game is in foreground before maa steps.
${ADB} -s "${ADB_SERIAL}" shell monkey -p com.hypergryph.arknights -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true

# If user edits plan file in project root, keep runtime plan in maa-config in sync.
if [ -f "${PLAN_SRC}" ]; then
  if [ ! -f "${PLAN_DST}" ] || ! cmp -s "${PLAN_SRC}" "${PLAN_DST}"; then
    cp -f "${PLAN_SRC}" "${PLAN_DST}"
    echo "$(timestamp) synced infrast plan ${PLAN_SRC} -> ${PLAN_DST}" >>"${LOG}"
  fi
fi

# Confirm custom infrast plan mapping before running real tasks.
# If mismatch or dry-run check fails, automatically fallback to default infrast task.
select_infrast_task

# Execution order: startup -> infrast -> award -> recruit -> mall -> fight
run_step "maa startup" 1 run_maa startup Official -a "${ADB_SERIAL}" --batch
run_step "maa run ${INFRAST_TASK_NAME}" 0 run_maa run "${INFRAST_TASK_NAME}" -a "${ADB_SERIAL}" --batch
run_step "maa run award" 0 run_maa run award -a "${ADB_SERIAL}" --batch
run_step "maa run recruit" 0 run_maa run recruit -a "${ADB_SERIAL}" --batch
run_step "maa run mall" 0 run_maa run mall -a "${ADB_SERIAL}" --batch
run_step "maa fight TA-9" 0 run_maa fight TA-9 -a "${ADB_SERIAL}" --expiring-medicine 99 --series 0 --batch
exit ${FAILED}
