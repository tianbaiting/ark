#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/tian/ark"
DOCKER="/usr/bin/docker"
LOG="${ROOT}/maa-update.log"
LOCK_FILE="/tmp/run_maa_update.lock"
LOCK_BUSY_RC=200
SELF_LOCKED_ENV="RUN_MAA_UPDATE_LOCKED"
MAA_TZ="${MAA_TZ:-UTC-9}"
UPDATE_MODE="${1:-${MAA_UPDATE_MODE:-hot-update}}"
MAX_LOG_BYTES="${MAX_LOG_BYTES:-$((10 * 1024 * 1024))}"

cd "${ROOT}"

timestamp() {
  date "+%F %T"
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
  ${DOCKER} compose run --rm -e TZ="${MAA_TZ}" maa maa hot-update --batch >>"${LOG}" 2>&1
  rc=$?
  ;;
update | full)
  # [EN] Full update is available for manual runs when MaaCore resources need replacement. / [CN] 全量更新用于手动替换 MaaCore 资源。
  ${DOCKER} compose run --rm -e TZ="${MAA_TZ}" maa maa update >>"${LOG}" 2>&1
  rc=$?
  ;;
*)
  echo "$(timestamp) unsupported update mode: ${UPDATE_MODE}" >>"${LOG}"
  rc=2
  ;;
esac
set -e
echo "$(timestamp) maa ${UPDATE_MODE} end rc=${rc}" >>"${LOG}"
exit "${rc}"
