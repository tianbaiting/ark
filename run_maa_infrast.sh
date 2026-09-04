#!/usr/bin/env bash
set -euo pipefail
exec 0</dev/null

# ============================================================
# === USER CONFIG（日常修改这里，其他变量一般不动）===
# ============================================================
# [EN] Fight stage: auto prefers active-event orundum stages; override with FIGHT_STAGE=XX-1. / [CN] 战斗关卡：auto 优先当前活动搓玉关；可用 FIGHT_STAGE=XX-1 临时覆盖。
FIGHT_STAGE="${FIGHT_STAGE:-auto}"
FIGHT_ACTIVITY_CLIENT="${FIGHT_ACTIVITY_CLIENT:-Official}"
FIGHT_AUTO_FALLBACK_STAGE="${FIGHT_AUTO_FALLBACK_STAGE:-AP-5}"
# [EN] Run weekly annihilation before normal farming on the first two CN-server weekdays. / [CN] 国服每周前两天先跑剿灭，再进行普通刷图。
ENABLE_ANNIHILATION="${ENABLE_ANNIHILATION:-true}"
ANNIHILATION_WEEKDAYS="${ANNIHILATION_WEEKDAYS:-1,2}"
CLIENT_TIME_ZONE="${CLIENT_TIME_ZONE:-Asia/Shanghai}"

# 基建排班 JSON（放在仓库根目录）。
INFRAST_PLAN_FILE="${INFRAST_PLAN_FILE:-243_4times_tbt20251104_noskip.json}"

# 客户端时区（POSIX TZ，"西负东正"反向：UTC-9 = UTC+09:00 = JST）。
# CN 服在日本本地运行：UTC-9。回国内运行改成 UTC-8。
MAA_TZ="${MAA_TZ:-UTC-9}"

# 超时：默认每步 30m，fight 单独 3h。防止 maa 异常卡死整轮 cron。
DEFAULT_STEP_TIMEOUT="${DEFAULT_STEP_TIMEOUT:-30m}"
FIGHT_TIMEOUT="${FIGHT_TIMEOUT:-3h}"

# 仓库扫描缓存过期天数：超过就重新扫描。
DEPOT_SCAN_INTERVAL_DAYS="${DEPOT_SCAN_INTERVAL_DAYS:-7}"
# [EN] Operator ownership changes slowly, so a biweekly scan is enough for copilot compatibility matching. / [CN] 干员持有情况变化较慢，每两周扫描一次即可用于作业兼容性匹配。
OPERBOX_SCAN_INTERVAL_DAYS="${OPERBOX_SCAN_INTERVAL_DAYS:-14}"

# [EN] Clear at most one pending event stage per scheduled run before spending the remaining sanity. / [CN] 每轮定时任务最多首通一个活动关卡，再消耗剩余理智。
ENABLE_AUTO_COPILOT="${ENABLE_AUTO_COPILOT:-true}"
AUTO_COPILOT_SCOPE="${AUTO_COPILOT_SCOPE:-normal,ex,s}"
AUTO_COPILOT_EX_DELAY_DAYS="${AUTO_COPILOT_EX_DELAY_DAYS:-7}"
AUTO_COPILOT_S_DELAY_DAYS="${AUTO_COPILOT_S_DELAY_DAYS:-14}"
AUTO_COPILOT_FORMATION_INDEX="${AUTO_COPILOT_FORMATION_INDEX:-4}"

# 日志阈值：超过就把 maa-cron.log 轮换成 maa-cron.log.1。
MAX_LOG_BYTES="${MAX_LOG_BYTES:-$((20 * 1024 * 1024))}"
# ============================================================

# Project-local runtime settings.
ROOT="/home/tian/ark"
PROFILE_FILE="${ROOT}/maa-config/profiles/default.toml"
DEPOT_CACHE="${ROOT}/depot_cache.json"
OPERBOX_CACHE="${ROOT}/operbox_cache.json"
AUTO_COPILOT_STATE="${ROOT}/auto_copilot_state.json"
AUTO_COPILOT_DOWNLOAD_DIR="${ROOT}/maa-cache/auto-copilot"
AUTO_COPILOT_CONTAINER_DIR="/root/.cache/maa/auto-copilot"
ACTIVITY_MANIFEST="${ROOT}/maa-cache/StageActivityV2.json"
# [EN] Read the device address from the profile so cron cannot silently drift to an obsolete serial. / [CN] 从配置档读取设备地址，避免 cron 静默使用已过期的序列号。
ADB_SERIAL="${ADB_SERIAL:-$(sed -n 's/^[[:space:]]*address[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${PROFILE_FILE}" | head -n1)}"
ADB="/usr/bin/adb"
DOCKER="/usr/bin/docker"
JQ="/usr/bin/jq"
LOG="${ROOT}/maa-cron.log"
FAILED=0
# [EN] Share one lock with update jobs so MaaCore resources are never replaced while a task is running. / [CN] 与更新任务共用同一把锁，避免任务运行时替换 MaaCore 资源。
LOCK_FILE="${MAA_AUTOMATION_LOCK_FILE:-/tmp/maa_automation.lock}"
PID_FILE="/tmp/run_maa_infrast.pid"
SCREEN_OFF_POCKET_STATE_FILE="/tmp/run_maa_infrast.screen_off_pocket"
LOCK_BUSY_RC=200
SELF_LOCKED_ENV="RUN_MAA_INFRAST_LOCKED"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-30m}"
CHILD_STOP_GRACE_SECONDS="${CHILD_STOP_GRACE_SECONDS:-20}"
STOP_WAIT_SECONDS="${STOP_WAIT_SECONDS:-30}"
ADB_READY_RETRIES="${ADB_READY_RETRIES:-3}"
ADB_RETRY_DELAY_SECONDS="${ADB_RETRY_DELAY_SECONDS:-5}"
# Default to resetting display overrides so the phone returns to system resolution after exit.
# 默认退出时重置显示覆盖参数，避免脚本结束后手机仍停留在临时分辨率。
DISPLAY_RESTORE_MODE="${DISPLAY_RESTORE_MODE:-reset}"
# Default to disabling stay-awake after exit so charging will not keep the phone screen on.
# 默认退出后关闭充电常亮，避免脚本结束后手机继续常亮。
STAY_ON_EXIT_MODE="${STAY_ON_EXIT_MODE:-disable}"
PLAN_SRC="${ROOT}/${INFRAST_PLAN_FILE}"
PLAN_DST="${ROOT}/maa-config/infrast/${INFRAST_PLAN_FILE}"
INFRAST_TASK_NAME="infrast"
ORIG_STAY_ON="0"
TEMP_STAY_ON_SET=0
ORIG_SCREEN_OFF_POCKET=""
TEMP_SCREEN_OFF_POCKET_SET=0
SLEEP_SCREEN_ON_EXIT=0
ORIG_WM_SIZE_OVERRIDE=""
ORIG_WM_DENSITY_OVERRIDE=""
TEMP_WM_SIZE_SET=0
TEMP_WM_DENSITY_SET=0
CURRENT_CMD_PID=""

cd "${ROOT}"

# Rotate log if it grew too large; keep one .1 sibling. mv 是原子的，并发也安全。
if [ -f "${LOG}" ]; then
  log_size_bytes="$(stat -c%s "${LOG}" 2>/dev/null || echo 0)"
  if [ "${log_size_bytes}" -gt "${MAX_LOG_BYTES}" ]; then
    mv -f "${LOG}" "${LOG}.1" >/dev/null 2>&1 || true
  fi
  unset log_size_bytes
fi

timestamp() {
  date "+%F %T"
}

show_usage() {
  cat <<EOF
Usage: $0 [start|stop|status|help]
  start   run the scripted MAA workflow (default)
  stop    stop the active workflow and restore phone state via cleanup
  status  show whether the workflow is currently running
  help    show this message
EOF
}

read_pid_file() {
  local pid=""

  if [ ! -f "${PID_FILE}" ]; then
    return 1
  fi

  pid="$(tr -d '[:space:]' <"${PID_FILE}" 2>/dev/null || true)"
  if [[ "${pid}" =~ ^[0-9]+$ ]]; then
    printf "%s\n" "${pid}"
    return 0
  fi

  rm -f "${PID_FILE}" >/dev/null 2>&1 || true
  return 1
}

pid_belongs_to_script() {
  local pid="$1"
  local args=""

  if ! [[ "${pid}" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  if ! kill -0 "${pid}" >/dev/null 2>&1; then
    return 1
  fi

  args="$(ps -p "${pid}" -o args= 2>/dev/null || true)"
  [[ "${args}" == *"run_maa_infrast.sh"* ]]
}

get_active_run_pid() {
  local pid=""

  pid="$(read_pid_file 2>/dev/null || true)"
  if [ -n "${pid}" ] && pid_belongs_to_script "${pid}"; then
    printf "%s\n" "${pid}"
    return 0
  fi

  if [ -n "${pid}" ]; then
    rm -f "${PID_FILE}" >/dev/null 2>&1 || true
  fi

  return 1
}

wait_for_pid_exit() {
  local pid="$1"
  local timeout_seconds="$2"
  local waited=0

  while [ "${waited}" -lt "${timeout_seconds}" ]; do
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  return 1
}

remove_pid_file_if_owned() {
  local pid_in_file=""

  pid_in_file="$(read_pid_file 2>/dev/null || true)"
  if [ "${pid_in_file}" = "$$" ]; then
    rm -f "${PID_FILE}" >/dev/null 2>&1 || true
  fi
}

force_restore_device_state() {
  local screen_off_pocket_target=""

  ${ADB} start-server >/dev/null 2>&1 || true

  if [ "$(${ADB} -s "${ADB_SERIAL}" get-state 2>/dev/null || true)" != "device" ]; then
    echo "$(timestamp) stop recovery skipped: adb device not ready" >>"${LOG}"
    return 1
  fi

  ${ADB} -s "${ADB_SERIAL}" shell wm size reset >/dev/null 2>&1 || true
  ${ADB} -s "${ADB_SERIAL}" shell wm density reset >/dev/null 2>&1 || true
  ${ADB} -s "${ADB_SERIAL}" shell settings put global stay_on_while_plugged_in 0 >/dev/null 2>&1 || true
  if [ -f "${SCREEN_OFF_POCKET_STATE_FILE}" ]; then
    screen_off_pocket_target="$(tr -d '[:space:]' <"${SCREEN_OFF_POCKET_STATE_FILE}" 2>/dev/null || true)"
    if [[ "${screen_off_pocket_target}" =~ ^[0-9]+$ ]]; then
      ${ADB} -s "${ADB_SERIAL}" shell settings put system screen_off_pocket "${screen_off_pocket_target}" >/dev/null 2>&1 || true
    fi
    rm -f "${SCREEN_OFF_POCKET_STATE_FILE}" >/dev/null 2>&1 || true
  fi
  ${ADB} -s "${ADB_SERIAL}" shell input keyevent 223 >/dev/null 2>&1 || true
  echo "$(timestamp) stop recovery forced screen-off and wm reset" >>"${LOG}"
  return 0
}

handle_stop_command() {
  local pid=""

  pid="$(get_active_run_pid 2>/dev/null || true)"
  if [ -z "${pid}" ]; then
    echo "not running"
    exit 0
  fi

  echo "$(timestamp) stop requested pid=${pid}" >>"${LOG}"
  kill -TERM "${pid}" >/dev/null 2>&1 || true
  if wait_for_pid_exit "${pid}" "${STOP_WAIT_SECONDS}"; then
    echo "stopped pid=${pid}"
    exit 0
  fi

  echo "$(timestamp) stop timeout, sending SIGKILL pid=${pid}" >>"${LOG}"
  kill -KILL "${pid}" >/dev/null 2>&1 || true
  wait_for_pid_exit "${pid}" 5 || true
  rm -f "${PID_FILE}" >/dev/null 2>&1 || true
  force_restore_device_state || true
  echo "forced stop pid=${pid}"
  exit 0
}

handle_status_command() {
  local pid=""

  pid="$(get_active_run_pid 2>/dev/null || true)"
  if [ -n "${pid}" ]; then
    echo "running pid=${pid}"
    exit 0
  fi

  echo "not running"
  exit 1
}

COMMAND="${1:-start}"
case "${COMMAND}" in
start | run) ;;
stop)
  handle_stop_command
  ;;
status)
  handle_status_command
  ;;
help | -h | --help)
  show_usage
  exit 0
  ;;
*)
  show_usage >&2
  exit 2
  ;;
esac

# Use flock --close at process level so lock fd is not inherited by adb/docker child processes.
# 通过进程级 flock --close 避免锁文件描述符被 adb/docker 子进程继承导致“永久占锁”。
if [ "${!SELF_LOCKED_ENV:-0}" != "1" ]; then
  set +e
  /usr/bin/flock -n -E "${LOCK_BUSY_RC}" -o "${LOCK_FILE}" env "${SELF_LOCKED_ENV}=1" /usr/bin/bash "$0" "$@"
  rc=$?
  set -e
  if [ "${rc}" -eq "${LOCK_BUSY_RC}" ]; then
    echo "$(date "+%F %T") another run is active, skip this run" >>"${LOG}"
    exit 0
  fi
  exit "${rc}"
fi

printf "%s\n" "$$" >"${PID_FILE}"

stop_current_command() {
  local signal_name="$1"

  if [ -z "${CURRENT_CMD_PID}" ] || ! kill -0 "${CURRENT_CMD_PID}" >/dev/null 2>&1; then
    return 0
  fi

  kill -"${signal_name}" "${CURRENT_CMD_PID}" >/dev/null 2>&1 || true
  if wait_for_pid_exit "${CURRENT_CMD_PID}" "${CHILD_STOP_GRACE_SECONDS}"; then
    wait "${CURRENT_CMD_PID}" >/dev/null 2>&1 || true
    return 0
  fi

  echo "$(timestamp) current task stop timeout, sending TERM pid=${CURRENT_CMD_PID}" >>"${LOG}"
  kill -TERM "${CURRENT_CMD_PID}" >/dev/null 2>&1 || true
  if wait_for_pid_exit "${CURRENT_CMD_PID}" 5; then
    wait "${CURRENT_CMD_PID}" >/dev/null 2>&1 || true
    return 0
  fi

  echo "$(timestamp) current task stop timeout, sending KILL pid=${CURRENT_CMD_PID}" >>"${LOG}"
  kill -KILL "${CURRENT_CMD_PID}" >/dev/null 2>&1 || true
  wait "${CURRENT_CMD_PID}" >/dev/null 2>&1 || true
  return 0
}

on_interrupt() {
  trap - INT TERM HUP
  echo "$(timestamp) interrupt received, stopping current task" >>"${LOG}"
  stop_current_command INT
  exit 130
}

# Restore temporary display settings on any exit path.
cleanup() {
  local rc=$?
  local stay_on_target="${ORIG_STAY_ON}"
  trap - EXIT INT TERM HUP

  if [ "${TEMP_WM_SIZE_SET}" -eq 1 ]; then
    if [ "${DISPLAY_RESTORE_MODE}" = "original" ] && [ -n "${ORIG_WM_SIZE_OVERRIDE}" ]; then
      ${ADB} -s "${ADB_SERIAL}" shell wm size "${ORIG_WM_SIZE_OVERRIDE}" >/dev/null 2>&1 || true
      echo "$(timestamp) restored wm size override=${ORIG_WM_SIZE_OVERRIDE}" >>"${LOG}"
    else
      ${ADB} -s "${ADB_SERIAL}" shell wm size reset >/dev/null 2>&1 || true
      echo "$(timestamp) restored wm size reset" >>"${LOG}"
    fi
  fi

  if [ "${TEMP_WM_DENSITY_SET}" -eq 1 ]; then
    if [ "${DISPLAY_RESTORE_MODE}" = "original" ] && [ -n "${ORIG_WM_DENSITY_OVERRIDE}" ]; then
      ${ADB} -s "${ADB_SERIAL}" shell wm density "${ORIG_WM_DENSITY_OVERRIDE}" >/dev/null 2>&1 || true
      echo "$(timestamp) restored wm density override=${ORIG_WM_DENSITY_OVERRIDE}" >>"${LOG}"
    else
      ${ADB} -s "${ADB_SERIAL}" shell wm density reset >/dev/null 2>&1 || true
      echo "$(timestamp) restored wm density reset" >>"${LOG}"
    fi
  fi

  if [ "${TEMP_STAY_ON_SET}" -eq 1 ]; then
    if [ "${STAY_ON_EXIT_MODE}" = "disable" ]; then
      stay_on_target="0"
    fi
    ${ADB} -s "${ADB_SERIAL}" shell settings put global stay_on_while_plugged_in "${stay_on_target}" >/dev/null 2>&1 || true
    echo "$(timestamp) restored stay_on_while_plugged_in=${stay_on_target}" >>"${LOG}"
  fi

  if [ "${TEMP_SCREEN_OFF_POCKET_SET}" -eq 1 ]; then
    ${ADB} -s "${ADB_SERIAL}" shell settings put system screen_off_pocket "${ORIG_SCREEN_OFF_POCKET}" >/dev/null 2>&1 || true
    rm -f "${SCREEN_OFF_POCKET_STATE_FILE}" >/dev/null 2>&1 || true
    echo "$(timestamp) restored screen_off_pocket=${ORIG_SCREEN_OFF_POCKET}" >>"${LOG}"
  fi

  if [ "${SLEEP_SCREEN_ON_EXIT}" -eq 1 ]; then
    ${ADB} -s "${ADB_SERIAL}" shell input keyevent 223 >/dev/null 2>&1 || true
    echo "$(timestamp) requested screen sleep on exit" >>"${LOG}"
  fi

  remove_pid_file_if_owned
  exit "${rc}"
}

trap cleanup EXIT
trap on_interrupt INT TERM HUP

# Run one step, always log start/end, optionally fail-fast.
run_step() {
  local name="$1"
  local fatal="$2"
  local errexit_was_set=0
  shift 2

  if [[ "$-" == *e* ]]; then
    errexit_was_set=1
    set +e
  fi

  echo "$(timestamp) ${name} start" >>"${LOG}"
  "$@" >>"${LOG}" 2>&1 &
  CURRENT_CMD_PID=$!
  wait "${CURRENT_CMD_PID}"
  local rc=$?
  CURRENT_CMD_PID=""
  if [ "${errexit_was_set}" -eq 1 ]; then
    set -e
  fi
  echo "$(timestamp) ${name} end rc=${rc}" >>"${LOG}"

  if [ "${rc}" -eq 130 ]; then
    exit 130
  fi

  if [ "${rc}" -ne 0 ]; then
    FAILED=1
    if [ "${fatal}" -eq 1 ]; then
      exit "${rc}"
    fi
  fi
}

# Run one step and return its rc for fallback chains without setting FAILED.
run_step_soft() {
  local name="$1"
  local errexit_was_set=0
  shift

  if [[ "$-" == *e* ]]; then
    errexit_was_set=1
    set +e
  fi

  echo "$(timestamp) ${name} start" >>"${LOG}"
  "$@" >>"${LOG}" 2>&1 &
  CURRENT_CMD_PID=$!
  wait "${CURRENT_CMD_PID}"
  local rc=$?
  CURRENT_CMD_PID=""
  if [ "${errexit_was_set}" -eq 1 ]; then
    set -e
  fi
  echo "$(timestamp) ${name} end rc=${rc}" >>"${LOG}"

  if [ "${rc}" -eq 130 ]; then
    exit 130
  fi

  return "${rc}"
}

# [EN] Fight fallback chain: configured/auto stage -> AP-5 red tickets -> 1-7 base farming. / [CN] 刷图回退链：配置或自动关卡 -> AP-5 红票 -> 1-7 基础长草。
run_fight_with_fallback() {
  local rc=0

  # Temporarily relax `set -e` so fallback can inspect the failing rc explicitly.
  # 临时关闭 `set -e`，这样回退链可以显式读取失败返回码而不会被脚本提前中断。
  set +e
  run_step_soft "maa fight ${FIGHT_STAGE}" \
    run_maa_with_timeout "${FIGHT_TIMEOUT}" fight "${FIGHT_STAGE}" -a "${ADB_SERIAL}" --expiring-medicine 99 --series 0 --batch
  rc=$?
  set -e
  if [ "${rc}" -eq 0 ]; then
    echo "$(timestamp) fight selected stage=${FIGHT_STAGE}" >>"${LOG}"
    return 0
  fi

  echo "$(timestamp) fight fallback: ${FIGHT_STAGE} rc=${rc}, switch to AP-5" >>"${LOG}"
  set +e
  run_step_soft "maa fight AP-5" \
    run_maa_with_timeout "${FIGHT_TIMEOUT}" fight AP-5 -a "${ADB_SERIAL}" --expiring-medicine 99 --series 0 --batch
  rc=$?
  set -e
  if [ "${rc}" -eq 0 ]; then
    echo "$(timestamp) fight selected stage=AP-5" >>"${LOG}"
    return 0
  fi

  echo "$(timestamp) fight fallback: AP-5 rc=${rc}, switch to 1-7" >>"${LOG}"
  set +e
  run_step_soft "maa fight 1-7" \
    run_maa_with_timeout "${FIGHT_TIMEOUT}" fight 1-7 -a "${ADB_SERIAL}" --expiring-medicine 99 --series 0 --batch
  rc=$?
  set -e
  if [ "${rc}" -eq 0 ]; then
    echo "$(timestamp) fight selected stage=1-7" >>"${LOG}"
    return 0
  fi

  FAILED=1
  echo "$(timestamp) fight fallback exhausted: ${FIGHT_STAGE}/AP-5/1-7 all failed (last_rc=${rc})" >>"${LOG}"
  return 0
}

# Run maa-cli in container with fixed timezone and a default per-step timeout.
# 通过外层 timeout 防止单个子任务异常卡死整轮 cron。
run_maa() {
  timeout --signal=INT --kill-after=30s "${DEFAULT_STEP_TIMEOUT}" \
    ${DOCKER} compose run --rm -e TZ="${MAA_TZ}" maa maa "$@"
}

# Limit startup wall time to avoid hanging for many hours when device is offline.
# 对 startup 增加总时长限制，避免设备离线时卡住数小时。
run_maa_with_timeout() {
  local timeout_limit="$1"
  shift
  timeout --signal=INT --kill-after=30s "${timeout_limit}" ${DOCKER} compose run --rm -e TZ="${MAA_TZ}" maa maa "$@"
}

select_auto_fight_stage() {
  local output=""
  local selected=""
  local rc=0

  set +e
  output="$(run_maa activity --batch "${FIGHT_ACTIVITY_CLIENT}" 2>&1)"
  rc=$?
  set -e

  printf "%s\n" "${output}" >>"${LOG}"
  if [ "${rc}" -ne 0 ]; then
    echo "$(timestamp) maa activity failed rc=${rc}" >>"${LOG}"
    return 1
  fi

  set +e
  selected="$(printf "%s\n" "${output}" | "${ROOT}/scripts/maa_select_activity_stage.sh" 2>>"${LOG}")"
  rc=$?
  set -e

  if [ "${rc}" -ne 0 ] || [ -z "${selected}" ]; then
    echo "$(timestamp) maa activity has no event stage" >>"${LOG}"
    return 1
  fi

  printf "%s\n" "${selected}"
  return 0
}

resolve_fight_stage() {
  local selected=""
  local rc=0

  if [ "${FIGHT_STAGE}" != "auto" ]; then
    echo "$(timestamp) fight configured stage=${FIGHT_STAGE}" >>"${LOG}"
    return 0
  fi

  set +e
  selected="$(select_auto_fight_stage)"
  rc=$?
  set -e

  if [ "${rc}" -eq 0 ] && [ -n "${selected}" ]; then
    FIGHT_STAGE="${selected}"
    echo "$(timestamp) fight auto selected stage=${FIGHT_STAGE}" >>"${LOG}"
    return 0
  fi

  FIGHT_STAGE="${FIGHT_AUTO_FALLBACK_STAGE}"
  echo "$(timestamp) fight auto fallback stage=${FIGHT_STAGE}" >>"${LOG}"
  return 0
}

should_run_annihilation() {
  local client_weekday=""
  local client_hour=""

  if [ "${ENABLE_ANNIHILATION}" != "true" ]; then
    return 1
  fi

  client_weekday="$(TZ="${CLIENT_TIME_ZONE}" date +%u)"
  client_hour="$(TZ="${CLIENT_TIME_ZONE}" date +%H)"
  if [ "${client_hour#0}" -lt 4 ]; then
    return 1
  fi

  case ",${ANNIHILATION_WEEKDAYS}," in
  *,"${client_weekday}",*) return 0 ;;
  *) return 1 ;;
  esac
}

run_weekly_annihilation() {
  if ! should_run_annihilation; then
    return 0
  fi

  # [EN] Repeated Monday/Tuesday attempts finish the weekly quota even when one run starts with little sanity. / [CN] 周一、周二重复尝试，即使某次开始时理智不足也能补齐周常额度。
  run_step "maa fight Annihilation" 0 \
    run_maa_with_timeout "${FIGHT_TIMEOUT}" fight Annihilation -a "${ADB_SERIAL}" \
    --times 6 --expiring-medicine 99 --series 0 --batch
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
  echo "$(timestamp) maa infrast config verify start" >>"${LOG}"
  INFRAST_TASK_NAME="infrast"

  if verify_infrast_plan; then
    echo "$(timestamp) maa infrast config verify end rc=0 use=${INFRAST_TASK_NAME}" >>"${LOG}"
    return 0
  fi

  # If verify failed (network/log parsing issue), still force custom infrast task.
  echo "$(timestamp) maa infrast config verify failed, force use=${INFRAST_TASK_NAME}" >>"${LOG}"
  return 0
}

get_cache_age_days() {
  local cache_path="$1"
  local age="999"

  if [ -f "${cache_path}" ]; then
    age="$(python3 -c '
import json
import sys
from datetime import datetime

with open(sys.argv[1], encoding="utf-8") as stream:
    timestamp = json.load(stream).get("timestamp", "")
parsed = datetime.fromisoformat(timestamp)
print(max(0, (datetime.now(tz=parsed.tzinfo) - parsed).days))
' "${cache_path}" 2>/dev/null)" || age="999"
  fi

  if ! [[ "${age}" =~ ^[0-9]+$ ]]; then
    age="999"
  fi
  printf "%s\n" "${age}"
}

scan_inventory_if_stale() {
  local task_name="$1"
  local kind="$2"
  local cache_path="$3"
  local interval_days="$4"
  local age=""
  local raw_output=""
  local rc=0

  age="$(get_cache_age_days "${cache_path}")"
  if [ "${age}" -lt "${interval_days}" ]; then
    echo "$(timestamp) ${kind} cache fresh (${age} days < ${interval_days}), skip scan" >>"${LOG}"
    return 0
  fi

  echo "$(timestamp) ${kind} cache stale (${age} days >= ${interval_days}), scanning" >>"${LOG}"
  raw_output="$(mktemp "${TMPDIR:-/tmp}/maa_${kind}.XXXXXX")"
  set +e
  run_maa_with_timeout "${DEFAULT_STEP_TIMEOUT}" run "${task_name}" -a "${ADB_SERIAL}" --batch -v >"${raw_output}" 2>&1
  rc=$?
  set -e
  cat "${raw_output}" >>"${LOG}"
  echo "$(timestamp) maa ${kind} scan end rc=${rc}" >>"${LOG}"
  if [ "${rc}" -eq 0 ]; then
    python3 "${ROOT}/scripts/extract_maa_inventory.py" "${kind}" "${raw_output}" "${cache_path}" \
      2>>"${LOG}" || echo "$(timestamp) ${kind} scan: no completed inventory callback parsed" >>"${LOG}"
  fi
  rm -f "${raw_output}"
  return 0
}

run_auto_copilot() {
  local activity_output=""
  local plan_json=""
  local event_id=""
  local stage_key=""
  local stage_code=""
  local job_id=""
  local container_file=""
  local raid_mode="normal"
  local rc=0

  if [ "${ENABLE_AUTO_COPILOT}" != "true" ]; then
    return 0
  fi
  if [ ! -x "${JQ}" ] || [ ! -f "${ACTIVITY_MANIFEST}" ]; then
    echo "$(timestamp) auto-copilot skipped: jq or activity manifest missing" >>"${LOG}"
    return 0
  fi

  activity_output="$(mktemp "${TMPDIR:-/tmp}/maa_activity.XXXXXX")"
  set +e
  run_maa activity --batch "${FIGHT_ACTIVITY_CLIENT}" >"${activity_output}" 2>&1
  rc=$?
  set -e
  cat "${activity_output}" >>"${LOG}"
  if [ "${rc}" -ne 0 ]; then
    echo "$(timestamp) auto-copilot activity query failed rc=${rc}" >>"${LOG}"
    rm -f "${activity_output}"
    return 0
  fi

  set +e
  plan_json="$(python3 "${ROOT}/scripts/maa_auto_copilot.py" plan \
    --activity-file "${activity_output}" \
    --activity-manifest "${ACTIVITY_MANIFEST}" \
    --operbox-cache "${OPERBOX_CACHE}" \
    --state "${AUTO_COPILOT_STATE}" \
    --download-dir "${AUTO_COPILOT_DOWNLOAD_DIR}" \
    --container-download-dir "${AUTO_COPILOT_CONTAINER_DIR}" \
    --client "${FIGHT_ACTIVITY_CLIENT}" \
    --scope "${AUTO_COPILOT_SCOPE}" \
    --ex-delay-days "${AUTO_COPILOT_EX_DELAY_DAYS}" \
    --s-delay-days "${AUTO_COPILOT_S_DELAY_DAYS}" 2>>"${LOG}")"
  rc=$?
  set -e
  rm -f "${activity_output}"
  if [ "${rc}" -ne 0 ]; then
    echo "$(timestamp) auto-copilot planner failed rc=${rc}" >>"${LOG}"
    return 0
  fi
  if [ -z "${plan_json}" ]; then
    echo "$(timestamp) auto-copilot: no pending eligible event stage" >>"${LOG}"
    return 0
  fi

  set +e
  event_id="$(printf "%s\n" "${plan_json}" | "${JQ}" -er '.event_id')"
  stage_key="$(printf "%s\n" "${plan_json}" | "${JQ}" -er '.stage_key')"
  stage_code="$(printf "%s\n" "${plan_json}" | "${JQ}" -er '.stage_code')"
  job_id="$(printf "%s\n" "${plan_json}" | "${JQ}" -er '.job_id')"
  container_file="$(printf "%s\n" "${plan_json}" | "${JQ}" -er '.container_file')"
  raid_mode="$(printf "%s\n" "${plan_json}" | "${JQ}" -er 'if .raid then "raid" else "normal" end')"
  rc=$?
  set -e
  if [ "${rc}" -ne 0 ] || [ -z "${event_id}" ] || [ -z "${stage_key}" ] || \
    [ -z "${stage_code}" ] || [ -z "${job_id}" ] || [ -z "${container_file}" ]; then
    echo "$(timestamp) auto-copilot planner returned invalid JSON" >>"${LOG}"
    return 0
  fi

  echo "$(timestamp) auto-copilot selected stage=${stage_code} raid=${raid_mode} job=${job_id}" >>"${LOG}"
  set +e
  run_step_soft "maa copilot ${stage_code} job=${job_id}" \
    run_maa_with_timeout "${FIGHT_TIMEOUT}" copilot "${container_file}" \
    --raid "${raid_mode}" --formation --formation-index "${AUTO_COPILOT_FORMATION_INDEX}" \
    --support-unit-usage 1 -a "${ADB_SERIAL}" --batch
  rc=$?
  set -e

  if [ "${rc}" -eq 0 ]; then
    python3 "${ROOT}/scripts/maa_auto_copilot.py" success --state "${AUTO_COPILOT_STATE}" \
      --event-id "${event_id}" --stage-key "${stage_key}" --job-id "${job_id}" >>"${LOG}" 2>&1 || FAILED=1
    echo "$(timestamp) auto-copilot completed stage=${stage_code} raid=${raid_mode} job=${job_id}" >>"${LOG}"
  else
    python3 "${ROOT}/scripts/maa_auto_copilot.py" failure --state "${AUTO_COPILOT_STATE}" \
      --event-id "${event_id}" --stage-key "${stage_key}" --job-id "${job_id}" >>"${LOG}" 2>&1 || true
    FAILED=1
    echo "$(timestamp) auto-copilot failed stage=${stage_code} raid=${raid_mode} job=${job_id} rc=${rc}" >>"${LOG}"
  fi
  return 0
}

wait_for_adb_device() {
  local attempt=1
  local state=""

  while [ "${attempt}" -le "${ADB_READY_RETRIES}" ]; do
    ${ADB} start-server >/dev/null 2>&1 || true
    state="$(${ADB} -s "${ADB_SERIAL}" get-state 2>/dev/null || true)"
    if [ "${state}" = "device" ]; then
      return 0
    fi

    echo "$(timestamp) adb not ready attempt=${attempt}/${ADB_READY_RETRIES} state=${state:-none}" >>"${LOG}"
    # [EN] Ask ADB to renegotiate an offline transport before the next bounded check. / [CN] 在下一次有限检查前，让 ADB 重新协商离线传输连接。
    ${ADB} -s "${ADB_SERIAL}" reconnect >/dev/null 2>&1 || true
    if [ "${attempt}" -lt "${ADB_READY_RETRIES}" ]; then
      sleep "${ADB_RETRY_DELAY_SECONDS}"
    fi
    attempt=$((attempt + 1))
  done

  return 1
}

# Make sure adb daemon is ready.
if [ -z "${ADB_SERIAL}" ]; then
  echo "$(timestamp) adb device address missing in ${PROFILE_FILE}" >>"${LOG}"
  exit 2
fi
if ! wait_for_adb_device; then
  echo "$(timestamp) adb device not ready after ${ADB_READY_RETRIES} attempts: serial=${ADB_SERIAL}" >>"${LOG}"
  exit 1
fi

# Normalize display and keep screen awake to reduce OCR/interaction failures.
wm_size_raw="$(${ADB} -s "${ADB_SERIAL}" shell wm size 2>/dev/null | tr -d '\r' || true)"
wm_density_raw="$(${ADB} -s "${ADB_SERIAL}" shell wm density 2>/dev/null | tr -d '\r' || true)"
ORIG_WM_SIZE_OVERRIDE="$(printf "%s\n" "${wm_size_raw}" | sed -n 's/^Override size: //p' | head -n1)"
ORIG_WM_DENSITY_OVERRIDE="$(printf "%s\n" "${wm_density_raw}" | sed -n 's/^Override density: //p' | head -n1)"

${ADB} -s "${ADB_SERIAL}" shell wm size 1080x1920 >/dev/null 2>&1 || true
TEMP_WM_SIZE_SET=1
${ADB} -s "${ADB_SERIAL}" shell wm density 480 >/dev/null 2>&1 || true
TEMP_WM_DENSITY_SET=1

# Keep screen awake only during this run, then restore original value in cleanup().
ORIG_STAY_ON="$(${ADB} -s "${ADB_SERIAL}" shell settings get global stay_on_while_plugged_in 2>/dev/null | tr -d '\r' || true)"
if ! [[ "${ORIG_STAY_ON}" =~ ^[0-9]+$ ]]; then
  ORIG_STAY_ON="0"
fi
${ADB} -s "${ADB_SERIAL}" shell settings put global stay_on_while_plugged_in 3 >/dev/null 2>&1 || true
TEMP_STAY_ON_SET=1
SLEEP_SCREEN_ON_EXIT=1

# [EN] Samsung's pocket touch guard blocks screenshots and taps after cron wake-up. / [CN] 三星口袋防误触会在 cron 唤醒后遮挡截图和点击。
ORIG_SCREEN_OFF_POCKET="$(${ADB} -s "${ADB_SERIAL}" shell settings get system screen_off_pocket 2>/dev/null | tr -d '\r' || true)"
if ! [[ "${ORIG_SCREEN_OFF_POCKET}" =~ ^[0-9]+$ ]]; then
  ORIG_SCREEN_OFF_POCKET="1"
fi
printf "%s\n" "${ORIG_SCREEN_OFF_POCKET}" >"${SCREEN_OFF_POCKET_STATE_FILE}" 2>/dev/null || true
${ADB} -s "${ADB_SERIAL}" shell settings put system screen_off_pocket 0 >/dev/null 2>&1 || true
TEMP_SCREEN_OFF_POCKET_SET=1

${ADB} -s "${ADB_SERIAL}" shell input keyevent 224 >/dev/null 2>&1 || true
${ADB} -s "${ADB_SERIAL}" shell input keyevent 82 >/dev/null 2>&1 || true
${ADB} -s "${ADB_SERIAL}" shell input swipe 540 1600 540 400 300 >/dev/null 2>&1 || true

# [EN] Drop any retained stage/menu state before cron starts automation. / [CN] 清掉定时任务启动前残留的关卡或菜单状态。
${ADB} -s "${ADB_SERIAL}" shell am force-stop com.hypergryph.arknights >/dev/null 2>&1 || true
# Ensure game is in foreground before maa steps.
${ADB} -s "${ADB_SERIAL}" shell monkey -p com.hypergryph.arknights -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true

# Use maa-config/infrast as the single source of truth to avoid accidental overwrite.
if [ ! -f "${PLAN_DST}" ]; then
  if [ -f "${PLAN_SRC}" ]; then
    cp -f "${PLAN_SRC}" "${PLAN_DST}"
    echo "$(timestamp) initialized infrast plan ${PLAN_DST} from ${PLAN_SRC}" >>"${LOG}"
  else
    echo "$(timestamp) infrast plan missing: ${PLAN_DST}" >>"${LOG}"
  fi
fi

# Confirm custom infrast plan mapping before running real tasks.
# If dry-run check fails, still force custom task instead of fallback.
select_infrast_task

# [EN] Execution order: startup -> inventory scans?(if stale) -> infrast -> award -> recruit -> mall -> annihilation?(Mon/Tue) -> event copilot? -> fight -> closedown. / [CN] 执行顺序：启动 -> 库存扫描?(过期才跑) -> 基建 -> 奖励 -> 公招 -> 信用 -> 剿灭?(周一/二) -> 活动抄作业? -> 刷图 -> 关闭。
run_step "maa run startup_no_launch" 1 run_maa_with_timeout "${STARTUP_TIMEOUT}" run startup_no_launch -a "${ADB_SERIAL}" --batch

scan_inventory_if_stale depot depot "${DEPOT_CACHE}" "${DEPOT_SCAN_INTERVAL_DAYS}"
scan_inventory_if_stale operbox operbox "${OPERBOX_CACHE}" "${OPERBOX_SCAN_INTERVAL_DAYS}"

run_step "maa run ${INFRAST_TASK_NAME}" 0 run_maa run "${INFRAST_TASK_NAME}" -a "${ADB_SERIAL}" --batch
run_step "maa run award" 0 run_maa run award -a "${ADB_SERIAL}" --batch
run_step "maa run recruit" 0 run_maa run recruit -a "${ADB_SERIAL}" --batch
run_step "maa run mall" 0 run_maa run mall -a "${ADB_SERIAL}" --batch
run_weekly_annihilation
run_auto_copilot
resolve_fight_stage
run_fight_with_fallback

# Graceful shutdown: maa closedown 走游戏内退出流程；am force-stop 兜底防止后台残留。
run_step "maa closedown" 0 run_maa closedown Official -a "${ADB_SERIAL}" --batch
${ADB} -s "${ADB_SERIAL}" shell am force-stop com.hypergryph.arknights >/dev/null 2>&1 || true

exit ${FAILED}
