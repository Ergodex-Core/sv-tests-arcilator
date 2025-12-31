#!/usr/bin/env bash
set -euo pipefail

SVTESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_ROOT="$(cd "${SVTESTS_ROOT}/.." && pwd)"

TEST_LIST_FILE="${TEST_LIST_FILE:-"${WS_ROOT}/tempnotes/NOTES/m4_random_acceptance_tests.txt"}"

OUT_ARC="${OUT_ARC:-out_arcilator_m4_random_accept}"
OUT_VER="${OUT_VER:-out_Verilator_m4_random_accept}"

OVERRIDE_TEST_TIMEOUTS="${OVERRIDE_TEST_TIMEOUTS:-1800}"
FAIL_ON_GAPS="${FAIL_ON_GAPS:-1}"

# Exercise seed plumbing by default (does not assume a particular RNG sequence).
export SVTESTS_SIM_ARGS="${SVTESTS_SIM_ARGS:-+ntb_random_seed=1}"

if ! command -v z3 >/dev/null 2>&1; then
  echo "[error] z3 not found; Verilator needs it for randomize/constraints (M4)" >&2
  exit 2
fi

if [[ ! -f "${TEST_LIST_FILE}" ]]; then
  echo "[error] missing TEST_LIST_FILE=${TEST_LIST_FILE}" >&2
  exit 2
fi

readarray -t TESTS_ARR < <(grep -v '^[[:space:]]*$' "${TEST_LIST_FILE}" | grep -v '^[[:space:]]*#')
if [[ ${#TESTS_ARR[@]} -eq 0 ]]; then
  echo "[error] no tests in ${TEST_LIST_FILE}" >&2
  exit 2
fi

TESTS_STR="$(printf '%s ' "${TESTS_ARR[@]}")"

ensure_verilator() {
  local out_dir="$1"
  if [[ -x "${SVTESTS_ROOT}/${out_dir}/runners/bin/verilator" ]]; then
    return 0
  fi
  echo "[info] installing pinned Verilator into ${out_dir}/runners/bin"
  make -C "${SVTESTS_ROOT}" verilator OUT_DIR="${out_dir}" -j"$(nproc)"
}

echo "[run] arcilator_top → ${OUT_ARC} (SVTESTS_SIM_ARGS=${SVTESTS_SIM_ARGS})"
cd "${SVTESTS_ROOT}"
RUNNERS=arcilator_top ./one.sh report OUT_DIR="${OUT_ARC}" TESTS="${TESTS_STR}" -B -j"$(nproc)"

ensure_verilator "${OUT_VER}"
echo "[run] Verilator → ${OUT_VER} (OVERRIDE_TEST_TIMEOUTS=${OVERRIDE_TEST_TIMEOUTS}, SVTESTS_SIM_ARGS=${SVTESTS_SIM_ARGS})"
OVERRIDE_TEST_TIMEOUTS="${OVERRIDE_TEST_TIMEOUTS}" RUNNERS=Verilator ./one.sh report OUT_DIR="${OUT_VER}" TESTS="${TESTS_STR}" -B -j1

export OUT_ARC OUT_VER FAIL_ON_GAPS

python3 - <<'PY'
import csv
import os
import sys

out_arc = os.environ.get("OUT_ARC", "out_arcilator_m4_random_accept")
out_ver = os.environ.get("OUT_VER", "out_Verilator_m4_random_accept")
fail_on_gaps = os.environ.get("FAIL_ON_GAPS", "1").strip().lower() not in ("0", "false", "no", "off")

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
print("\\n".join(ver_only) if ver_only else "(none)")
print("")
print("=== Arcilator PASS / Verilator FAIL ===")
print("\\n".join(arc_only) if arc_only else "(none)")

if fail_on_gaps and ver_only:
    sys.exit(1)
PY
