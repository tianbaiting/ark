#!/usr/bin/env bash
set -euo pipefail

ADB_TARGET="${ADB_TARGET:-127.0.0.1:5555}"
ADB_CONNECT="${ADB_CONNECT:-1}"
DNS_AUTO_FIX="${DNS_AUTO_FIX:-1}"
DNS_PROBE_HOST="${DNS_PROBE_HOST:-api.maa.plus}"
DNS_FALLBACK_SERVERS="${DNS_FALLBACK_SERVERS:-1.1.1.1 8.8.8.8}"
RESOLV_CONF_PATH="/etc/resolv.conf"

has_dns_resolution() {
  getent hosts "$1" >/dev/null 2>&1
}

preserve_resolver_options() {
  if [ ! -f "${RESOLV_CONF_PATH}" ]; then
    return 0
  fi

  awk '
    $1 == "search" || $1 == "domain" || $1 == "options" {
      print
    }
  ' "${RESOLV_CONF_PATH}"
}

apply_dns_fallback() {
  local tmp
  local server

  tmp="$(mktemp)"
  for server in ${DNS_FALLBACK_SERVERS}; do
    printf 'nameserver %s\n' "${server}" >>"${tmp}"
  done
  preserve_resolver_options >>"${tmp}" || true
  cat "${tmp}" > "${RESOLV_CONF_PATH}"
  rm -f "${tmp}"
}

ensure_dns_resolution() {
  if [ "${DNS_AUTO_FIX}" = "0" ]; then
    return 0
  fi

  if has_dns_resolution "${DNS_PROBE_HOST}"; then
    return 0
  fi

  echo "DNS lookup failed for ${DNS_PROBE_HOST}; applying fallback resolvers: ${DNS_FALLBACK_SERVERS}" >&2
  apply_dns_fallback

  if has_dns_resolution "${DNS_PROBE_HOST}"; then
    echo "DNS lookup recovered for ${DNS_PROBE_HOST}" >&2
    return 0
  fi

  echo "DNS lookup still failed for ${DNS_PROBE_HOST} after fallback override" >&2
  return 0
}

command_needs_dns_fix() {
  if [ "$#" -lt 2 ]; then
    return 1
  fi

  if [ "$1" != "maa" ]; then
    return 1
  fi

  case "$2" in
    update|hot-update)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

if command_needs_dns_fix "$@"; then
  ensure_dns_resolution
fi

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
