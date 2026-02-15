#!/usr/bin/env bash
set -euo pipefail

ADB_TARGET="${ADB_TARGET:-127.0.0.1:5555}"
ADB_CONNECT="${ADB_CONNECT:-1}"

adb start-server >/dev/null

if [ "${ADB_CONNECT}" != "0" ]; then
  for i in {1..30}; do
    if adb connect "${ADB_TARGET}" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
fi

exec "$@"
