#!/usr/bin/env bash
set -euo pipefail

SVTESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LIST_PATH="${LIST_PATH:-"${SVTESTS_DIR}/tools/data/uvm138_questa_vcd_matches_buildobj4_strict.txt"}"
GOLD_ROOT="${GOLD_ROOT:-"${SVTESTS_DIR}/gold/questa_vcd_uvm138_m27_buildobj4_strict"}"
OUT_DIR="${OUT_DIR:-"${SVTESTS_DIR}/out_arcilator_vcd_vs_questa_uvm138_m27"}"

exec "${SVTESTS_DIR}/tools/verify_questa_vcd_set.sh" \
  --list "${LIST_PATH}" \
  --gold-root "${GOLD_ROOT}" \
  --out "${OUT_DIR}" \
  "$@"

