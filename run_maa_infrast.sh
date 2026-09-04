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

# 日志阈值：超过就把 maa-cron.log 轮换成 maa-cron.log.1。
MAX_LOG_BYTES="${MAX_LOG_BYTES:-$((20 * 1024 * 1024))}"
# ============================================================

# Project-local runtime settings.
ROOT="/home/tian/ark"
DEPOT_CACHE="${ROOT}/depot_cache.json"
ADB_SERIAL="RF8N316396H"
ADB="/usr/bin/adb"
DOCKER="/usr/bin/docker"
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

# Make sure adb daemon is ready.
${ADB} start-server >/dev/null 2>&1 || true

state="$(${ADB} -s "${ADB_SERIAL}" get-state 2>/dev/null || true)"
if [ "${state}" != "device" ]; then
  echo "$(timestamp) adb device not ready: ${state:-none}" >>"${LOG}"
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

# [EN] Execution order: startup -> depot?(if stale) -> infrast -> award -> recruit -> mall -> annihilation?(Mon/Tue) -> fight -> closedown. / [CN] 执行顺序：启动 -> 仓库扫描?(过期才跑) -> 基建 -> 奖励 -> 公招 -> 信用 -> 剿灭?(周一/二) -> 刷图 -> 关闭。
run_step "maa run startup_no_launch" 1 run_maa_with_timeout "${STARTUP_TIMEOUT}" run startup_no_launch -a "${ADB_SERIAL}" --batch

# [EN] Scan depot if cache is older than DEPOT_SCAN_INTERVAL_DAYS. / [CN] 仓库缓存超过指定天数则重新扫描。
if [ -f "${DEPOT_CACHE}" ]; then
  cache_ts="$(python3 -c "
import json, datetime
with open('${DEPOT_CACHE}') as f:
    c = json.load(f)
print(c.get('timestamp',''))
" 2>/dev/null)" || cache_ts=""
  if [ -n "${cache_ts}" ]; then
    cache_age_days="$(python3 -c "
from datetime import datetime, timezone
ts = datetime.fromisoformat('${cache_ts}')
age = (datetime.now(tz=ts.tzinfo) - ts).days
print(age)
" 2>/dev/null)" || cache_age_days="999"
  else
    cache_age_days="999"
  fi
else
  cache_age_days="999"
fi

if [ "${cache_age_days:-999}" -ge "${DEPOT_SCAN_INTERVAL_DAYS}" ]; then
  echo "$(timestamp) depot cache stale (${cache_age_days:-N/A} days >= ${DEPOT_SCAN_INTERVAL_DAYS}), scanning..." >>"${LOG}"
  depot_raw="${TMPDIR:-/tmp}/maa_depot_$$.txt"
  set +e
  run_maa_with_timeout "${DEFAULT_STEP_TIMEOUT}" run depot -a "${ADB_SERIAL}" --batch >"${depot_raw}" 2>&1
  depot_rc=$?
  set -e
  cat "${depot_raw}" >>"${LOG}"
  echo "$(timestamp) maa depot scan end rc=${depot_rc}" >>"${LOG}"
  if [ "${depot_rc}" -eq 0 ]; then
    python3 -c "
import json, re, datetime, sys
with open('${depot_raw}') as f:
    text = f.read()
items = None
for line in text.splitlines():
    if 'DepotInfo' not in line:
        continue
    m = re.search(r'\"data\"\s*:\s*\"(\{[^\"]*\})\"', line)
    if m:
        try:
            items = json.loads(m.group(1))
        except json.JSONDecodeError:
            pass
if not items:
    for m in re.finditer(r'\{\"[0-9]+\":\s*\d+(?:,\s*\"[0-9]+\":\s*\d+)*\}', text):
        try:
            items = json.loads(m.group(0))
            break
        except json.JSONDecodeError:
            pass
if items:
    cache = {'timestamp': datetime.datetime.now().isoformat(), 'items': items}
    with open('${DEPOT_CACHE}', 'w') as f:
        json.dump(cache, f, indent=2, ensure_ascii=False)
    print(f'depot cache updated: {len(items)} items', file=sys.stderr)
else:
    print('depot scan completed but no items parsed', file=sys.stderr)
    sys.exit(1)
" 2>>"${LOG}" || echo "$(timestamp) depot scan: no items parsed from output" >>"${LOG}"
  fi
  rm -f "${depot_raw}"
else
  echo "$(timestamp) depot cache fresh (${cache_age_days} days < ${DEPOT_SCAN_INTERVAL_DAYS}), skip scan" >>"${LOG}"
fi

run_step "maa run ${INFRAST_TASK_NAME}" 0 run_maa run "${INFRAST_TASK_NAME}" -a "${ADB_SERIAL}" --batch
run_step "maa run award" 0 run_maa run award -a "${ADB_SERIAL}" --batch
run_step "maa run recruit" 0 run_maa run recruit -a "${ADB_SERIAL}" --batch
run_step "maa run mall" 0 run_maa run mall -a "${ADB_SERIAL}" --batch
run_weekly_annihilation
resolve_fight_stage
run_fight_with_fallback

# Graceful shutdown: maa closedown 走游戏内退出流程；am force-stop 兜底防止后台残留。
run_step "maa closedown" 0 run_maa closedown Official -a "${ADB_SERIAL}" --batch
${ADB} -s "${ADB_SERIAL}" shell am force-stop com.hypergryph.arknights >/dev/null 2>&1 || true

exit ${FAILED}
