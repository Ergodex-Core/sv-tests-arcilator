#!/usr/bin/env bash
set -euo pipefail

SVTESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TEST_LIST_FILE="${TEST_LIST_FILE:-"${SVTESTS_ROOT}/tools/data/uvm_hard_tests.txt"}"

OUT_ARC="${OUT_ARC:-out_arcilator_uvm_hard_h2h_verilator}"
OUT_VER="${OUT_VER:-out_verilator_uvm_hard_h2h_arcilator}"

WORKERS_ARC="${WORKERS_ARC:-"$(nproc)"}"
WORKERS_VER="${WORKERS_VER:-1}"

FAIL_ON_GAPS="${FAIL_ON_GAPS:-1}"

maybe_verilator_bin="${SVTESTS_ROOT}/third_party/tools/verilator/bin"
if command -v verilator >/dev/null 2>&1; then
  if ! verilator --help 2>/dev/null | grep -q -- '--timing'; then
    if [[ -d "${maybe_verilator_bin}" ]]; then
      export PATH="${maybe_verilator_bin}:${PATH}"
    fi
  fi
elif [[ -d "${maybe_verilator_bin}" ]]; then
  export PATH="${maybe_verilator_bin}:${PATH}"
fi

for tool in verilator; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "[error] required tool not found in PATH: ${tool}" >&2
    exit 2
  fi
done

if [[ ! -f "${TEST_LIST_FILE}" ]]; then
  echo "[error] missing TEST_LIST_FILE=${TEST_LIST_FILE}" >&2
  exit 2
fi

readarray -t TESTS_ARR < <(grep -v '^#' "${TEST_LIST_FILE}" | sed '/^\s*$/d')
if [[ ${#TESTS_ARR[@]} -eq 0 ]]; then
  echo "[error] no tests selected from ${TEST_LIST_FILE}" >&2
  exit 2
fi

TESTS_STR="$(printf '%s ' "${TESTS_ARR[@]}")"

echo "[run] arcilator_top → ${OUT_ARC} (workers=${WORKERS_ARC})"
cd "${SVTESTS_ROOT}"
export ARCILATOR_VCD_DT="${ARCILATOR_VCD_DT:-1}"
export ARCILATOR_CYCLES="${ARCILATOR_CYCLES:-10000}"
export ARCILATOR_TRACE_CYCLES="${ARCILATOR_TRACE_CYCLES:-0}"
RUNNERS=arcilator_top ./one.sh report OUT_DIR="${OUT_ARC}" TESTS="${TESTS_STR}" -B -j"${WORKERS_ARC}"

echo "[run] Verilator → ${OUT_VER} (workers=${WORKERS_VER})"
RUNNERS=Verilator ./one.sh report OUT_DIR="${OUT_VER}" TESTS="${TESTS_STR}" -B -j"${WORKERS_VER}"

export OUT_ARC OUT_VER FAIL_ON_GAPS

python3 - <<'PY'
import csv
import os
import sys

out_arc = os.environ.get("OUT_ARC", "out_arcilator_uvm_hard_h2h_verilator")
out_ver = os.environ.get("OUT_VER", "out_verilator_uvm_hard_h2h_arcilator")
fail_on_gaps = os.environ.get("FAIL_ON_GAPS", "1").strip().lower() not in ("", "0", "false", "no", "off")

arc_csv = os.path.join(out_arc, "report", "report.csv")
ver_csv = os.path.join(out_ver, "report", "report.csv")

def load(path: str):
    with open(path, newline="") as f:
        return {r["TestName"]: r for r in csv.DictReader(f)}

def passed(row) -> bool:
    return row.get("Pass") == "True"

arc = load(arc_csv)
ver = load(ver_csv)
common = set(arc) & set(ver)

ver_only = sorted(t for t in common if passed(ver[t]) and not passed(arc[t]))
arc_only = sorted(t for t in common if passed(arc[t]) and not passed(ver[t]))

print(f"[csv] {arc_csv}")
print(f"[csv] {ver_csv}")
print(f"[common] {len(common)} tests")
print(f"[pass] arcilator={sum(passed(arc[t]) for t in common)} verilator={sum(passed(ver[t]) for t in common)}")
print("")
print("=== Verilator PASS / Arcilator FAIL ===")
print("\n".join(ver_only) if ver_only else "(none)")
print("")
print("=== Arcilator PASS / Verilator FAIL ===")
print("\n".join(arc_only) if arc_only else "(none)")

if fail_on_gaps and ver_only:
    sys.exit(1)
PY
