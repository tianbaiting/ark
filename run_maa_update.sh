#!/usr/bin/env bash
set -euo pipefail
exec 0</dev/null

ROOT="${MAA_ROOT:-/home/tian/ark}"
DOCKER="${DOCKER:-/usr/bin/docker}"
LOG="${ROOT}/maa-update.log"
# [EN] Daily gameplay and updates must be mutually exclusive because both use the same mounted MaaCore data. / [CN] 日常任务与更新会使用同一份挂载的 MaaCore 数据，因此必须互斥运行。
LOCK_FILE="${MAA_AUTOMATION_LOCK_FILE:-/tmp/maa_automation.lock}"
LOCK_BUSY_RC=200
SELF_LOCKED_ENV="RUN_MAA_UPDATE_LOCKED"
MAA_TZ="${MAA_TZ:-UTC-9}"
UPDATE_MODE="${1:-${MAA_UPDATE_MODE:-hot-update}}"
MAX_LOG_BYTES="${MAX_LOG_BYTES:-$((10 * 1024 * 1024))}"
UPDATE_TIMEOUT="${UPDATE_TIMEOUT:-30m}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-45m}"
UPDATE_RETRIES="${UPDATE_RETRIES:-3}"
UPDATE_RETRY_DELAY_SECONDS="${UPDATE_RETRY_DELAY_SECONDS:-20}"

cd "${ROOT}"

timestamp() {
  date "+%F %T"
}

run_logged() {
  local name="$1"
  local errexit_was_set=0
  shift

  if [[ "$-" == *e* ]]; then
    errexit_was_set=1
    set +e
  fi
  echo "$(timestamp) ${name} start" >>"${LOG}"
  "$@" >>"${LOG}" 2>&1
  local rc=$?
  if [ "${errexit_was_set}" -eq 1 ]; then
    set -e
  fi
  echo "$(timestamp) ${name} end rc=${rc}" >>"${LOG}"
  return "${rc}"
}

run_with_retry() {
  local name="$1"
  local attempt=1
  local errexit_was_set=0
  local rc=0
  shift

  if [[ "$-" == *e* ]]; then
    errexit_was_set=1
    set +e
  fi
  while [ "${attempt}" -le "${UPDATE_RETRIES}" ]; do
    run_logged "${name} attempt=${attempt}/${UPDATE_RETRIES}" "$@"
    rc=$?
    if [ "${rc}" -eq 0 ]; then
      if [ "${errexit_was_set}" -eq 1 ]; then
        set -e
      fi
      return 0
    fi
    if [ "${attempt}" -lt "${UPDATE_RETRIES}" ]; then
      # [EN] Transient CDN and GitHub resets are common; bounded retries avoid waiting for the next cron window. / [CN] CDN 与 GitHub 偶发断连较常见；有限重试可避免一直等到下个 cron 周期。
      sleep "${UPDATE_RETRY_DELAY_SECONDS}"
    fi
    attempt=$((attempt + 1))
  done

  if [ "${errexit_was_set}" -eq 1 ]; then
    set -e
  fi
  return "${rc}"
}

run_maa_update() {
  timeout --signal=INT --kill-after=30s "${UPDATE_TIMEOUT}" \
    "${DOCKER}" compose run --rm -e TZ="${MAA_TZ}" maa maa update --batch
}

run_maa_hot_update() {
  timeout --signal=INT --kill-after=30s "${UPDATE_TIMEOUT}" \
    "${DOCKER}" compose run --rm -e TZ="${MAA_TZ}" maa maa hot-update --batch
}

verify_installation() {
  run_logged "maa version verify" \
    timeout --signal=INT --kill-after=30s "${UPDATE_TIMEOUT}" \
    "${DOCKER}" compose run --rm -e TZ="${MAA_TZ}" maa maa version || return $?

  # [EN] Version output alone cannot detect an incompatible Core/resource pair; parsing the real task catches that regression. / [CN] 仅看版本号无法发现 Core 与资源不兼容；解析真实任务可捕获这类回归。
  run_logged "maa infrast dry-run verify" \
    timeout --signal=INT --kill-after=30s "${UPDATE_TIMEOUT}" \
    "${DOCKER}" compose run --rm -e TZ="${MAA_TZ}" maa maa run infrast --dry-run --batch
}

if [ -f "${LOG}" ]; then
  log_size_bytes="$(stat -c%s "${LOG}" 2>/dev/null || echo 0)"
  if [ "${log_size_bytes}" -gt "${MAX_LOG_BYTES}" ]; then
    mv -f "${LOG}" "${LOG}.1" >/dev/null 2>&1 || true
  fi
  unset log_size_bytes
fi

if [ "${!SELF_LOCKED_ENV:-0}" != "1" ]; then
  set +e
  /usr/bin/flock -n -E "${LOCK_BUSY_RC}" -o "${LOCK_FILE}" env "${SELF_LOCKED_ENV}=1" /usr/bin/bash "$0" "$@"
  rc=$?
  set -e
  if [ "${rc}" -eq "${LOCK_BUSY_RC}" ]; then
    echo "$(timestamp) another update is active, skip this run" >>"${LOG}"
    exit 0
  fi
  exit "${rc}"
fi

echo "$(timestamp) maa ${UPDATE_MODE} start" >>"${LOG}"
set +e
case "${UPDATE_MODE}" in
hot-update | hot | resource | resources)
  # [EN] Hot update refreshes stage/activity resources without replacing MaaCore. / [CN] 热更新只刷新关卡和活动资源，不替换 MaaCore。
  run_with_retry "maa hot-update" run_maa_hot_update
  rc=$?
  ;;
update | full)
  # [EN] Rebuild first to update maa-cli, then update Core/resources and reject an incompatible installation. / [CN] 先重建镜像更新 maa-cli，再更新 Core/资源并拒绝不兼容的安装结果。
  run_logged "maa image rebuild" \
    timeout --signal=INT --kill-after=30s "${BUILD_TIMEOUT}" \
    "${DOCKER}" compose build --pull --no-cache maa
  rc=$?
  if [ "${rc}" -eq 0 ]; then
    run_with_retry "maa core update" run_maa_update
    rc=$?
  fi
  if [ "${rc}" -eq 0 ]; then
    verify_installation
    rc=$?
  fi
  ;;
*)
  echo "$(timestamp) unsupported update mode: ${UPDATE_MODE}" >>"${LOG}"
  rc=2
  ;;
esac
set -e
echo "$(timestamp) maa ${UPDATE_MODE} end rc=${rc}" >>"${LOG}"
exit "${rc}"
