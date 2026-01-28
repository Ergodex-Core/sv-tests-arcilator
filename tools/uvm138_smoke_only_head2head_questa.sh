#!/usr/bin/env bash
set -euo pipefail

SVTESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export TEST_LIST_FILE="${TEST_LIST_FILE:-"${SVTESTS_ROOT}/tools/data/uvm138_questa_vcd_tests_smoke_only.txt"}"

# Smoke-only tests have no meaningful hardware waveforms; prefer outcome parity
# and keep tracing off for speed.
export ARCILATOR_VCD_DT="${ARCILATOR_VCD_DT:-1}"
export ARCILATOR_CYCLES="${ARCILATOR_CYCLES:-10000}"
export ARCILATOR_TRACE_CYCLES="${ARCILATOR_TRACE_CYCLES:-0}"

exec "${SVTESTS_ROOT}/tools/uvm138_head2head_questa.sh" "$@"
