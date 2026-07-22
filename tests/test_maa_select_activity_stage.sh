#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELECTOR="${ROOT}/scripts/maa_select_activity_stage.sh"

fail() {
  printf "FAIL: %s\n" "$1" >&2
  exit 1
}

assert_selects() {
  local expected="$1"
  local input="$2"
  local actual=""

  actual="$(printf "%s\n" "${input}" | "${SELECTOR}")" || fail "selector returned non-zero for ${expected}"
  [ "${actual}" = "${expected}" ] || fail "expected ${expected}, got ${actual}"
}

assert_no_selection() {
  local input="$1"

  if printf "%s\n" "${input}" | "${SELECTOR}" >/tmp/maa_select_stage_test.out 2>/tmp/maa_select_stage_test.err; then
    fail "expected no selection, got $(cat /tmp/maa_select_stage_test.out)"
  fi
}

assert_selects "MT-6" 'Opening side story stages:
- SideStory「众生行记」复刻
  - MT-10: 化合切削液
  - MT-9: 研磨石
  - MT-8: 酮凝集组
  - MT-6: 搓玉效率0.69'

assert_selects "UR-5" 'Opening side story stages:
- サイドストーリー「約束されざる地」
  - UR-8: 素子結晶
  - UR-7: 熾合金
  - UR-6: 中級エステル
  - UR-5: 1理性あたり0.7合成玉'

assert_selects "BB-5" 'Opening side story stages:
- SideStory "example"
  - BB-8: Loxic Kohl
  - BB-5: 0.7 Orundum per sanity'

assert_no_selection 'Opening side story stages:
- SideStory「众生行记」复刻
  - MT-10: 化合切削液
  - MT-9: 研磨石
  - MT-8: 酮凝集组'

rm -f /tmp/maa_select_stage_test.out /tmp/maa_select_stage_test.err
printf "PASS\n"
