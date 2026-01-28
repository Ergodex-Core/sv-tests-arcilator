#!/usr/bin/env bash
set -euo pipefail

SVTESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_ROOT="$(cd "${SVTESTS_ROOT}/.." && pwd)"

TEST_LIST_FILE="${TEST_LIST_FILE:-"${SVTESTS_ROOT}/tools/data/uvm138_tests.txt"}"

OUT_ARC="${OUT_ARC:-out_arcilator_uvm138_head2head_questa}"
OUT_QUESTA="${OUT_QUESTA:-out_questa_uvm138_head2head_arcilator}"

WORKERS_ARC="${WORKERS_ARC:-"$(nproc)"}"
WORKERS_QUESTA="${WORKERS_QUESTA:-1}"

FAIL_ON_GAPS="${FAIL_ON_GAPS:-1}"
INCLUDE_SHOULD_FAIL="${INCLUDE_SHOULD_FAIL:-0}"

if [[ -n "${QUESTA_BIN_DIR:-}" ]]; then
  export PATH="${QUESTA_BIN_DIR}:${PATH}"
else
  maybe_bin="${WS_ROOT}/questa/questa_fse/linux_x86_64"
  if [[ -d "${maybe_bin}" ]]; then
    export PATH="${maybe_bin}:${PATH}"
  fi
fi

if [[ -z "${SALT_LICENSE_SERVER:-}" ]]; then
  maybe_license="${WS_ROOT}/LR-277765_License.dat"
  if [[ -f "${maybe_license}" ]]; then
    export SALT_LICENSE_SERVER="${maybe_license}"
  fi
fi

for tool in vlog vsim vlib; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "[error] required Questa tool not found in PATH: ${tool}" >&2
    echo "[hint] set QUESTA_BIN_DIR=/path/to/questa/bin (or install under ${WS_ROOT}/questa/)" >&2
    exit 2
  fi
done

if [[ ! -f "${TEST_LIST_FILE}" ]]; then
  echo "[error] missing TEST_LIST_FILE=${TEST_LIST_FILE}" >&2
  exit 2
fi

filter_should_fail() {
  python3 - "${SVTESTS_ROOT}" "${TEST_LIST_FILE}" "${INCLUDE_SHOULD_FAIL}" <<'PY'
import re
import sys
from pathlib import Path

svtests_root = Path(sys.argv[1])
list_path = Path(sys.argv[2])
include_should_fail = sys.argv[3].strip().lower() not in ("", "0", "false", "no", "off")

meta_re = re.compile(r"^\s*:([a-zA-Z_-]+):\s*(.+)$")

def is_should_fail(test_rel: str) -> bool:
    p = svtests_root / "tests" / test_rel
    try:
        meta = {}
        for line in p.read_text(encoding="utf-8", errors="ignore").splitlines()[:120]:
            m = meta_re.match(line)
            if not m:
                continue
            meta[m.group(1).lower()] = m.group(2).strip()
        return meta.get("should_fail", "0").strip() == "1" or "should_fail_because" in meta
    except OSError:
        return False

for raw in list_path.read_text(encoding="utf-8", errors="ignore").splitlines():
    rel = raw.strip()
    if not rel or rel.startswith("#"):
        continue
    if not include_should_fail and is_should_fail(rel):
        continue
    print(rel)
PY
}

readarray -t TESTS_ARR < <(filter_should_fail)
if [[ ${#TESTS_ARR[@]} -eq 0 ]]; then
  echo "[error] no tests selected from ${TEST_LIST_FILE}" >&2
  exit 2
fi

TESTS_STR="$(printf '%s ' "${TESTS_ARR[@]}")"

# tests/generated are required for the UVM138 list; generate them if missing.
if [[ ! -d "${SVTESTS_ROOT}/tests/generated" ]]; then
  echo "[info] tests/generated missing; running template generator"
  make -C "${SVTESTS_ROOT}" generate-template_generator -j"$(nproc)"
fi

echo "[run] arcilator_top → ${OUT_ARC} (workers=${WORKERS_ARC})"
cd "${SVTESTS_ROOT}"
RUNNERS=arcilator_top ./one.sh report OUT_DIR="${OUT_ARC}" TESTS="${TESTS_STR}" -B -j"${WORKERS_ARC}"

echo "[run] Questa_vcd → ${OUT_QUESTA} (workers=${WORKERS_QUESTA})"
RUNNERS=Questa_vcd ./one.sh report OUT_DIR="${OUT_QUESTA}" TESTS="${TESTS_STR}" -B -j"${WORKERS_QUESTA}"

export OUT_ARC OUT_QUESTA FAIL_ON_GAPS

python3 - <<'PY'
import csv
import os
import sys

out_arc = os.environ.get("OUT_ARC", "out_arcilator_uvm138_head2head_questa")
out_questa = os.environ.get("OUT_QUESTA", "out_questa_uvm138_head2head_arcilator")
fail_on_gaps = os.environ.get("FAIL_ON_GAPS", "1").strip().lower() not in ("", "0", "false", "no", "off")

arc_csv = os.path.join(out_arc, "report", "report.csv")
questa_csv = os.path.join(out_questa, "report", "report.csv")

def load(path: str):
    with open(path, newline="") as f:
        return {r["TestName"]: r for r in csv.DictReader(f)}

def passed(row) -> bool:
    return row.get("Pass") == "True"

arc = load(arc_csv)
questa = load(questa_csv)
common = set(arc) & set(questa)

questa_only = sorted(t for t in common if passed(questa[t]) and not passed(arc[t]))
arc_only = sorted(t for t in common if passed(arc[t]) and not passed(questa[t]))

print(f"[csv] {arc_csv}")
print(f"[csv] {questa_csv}")
print(f"[common] {len(common)} tests")
print(f"[pass] arcilator={sum(passed(arc[t]) for t in common)} questa={sum(passed(questa[t]) for t in common)}")
print("")
print("=== Questa PASS / Arcilator FAIL ===")
print("\n".join(questa_only) if questa_only else "(none)")
print("")
print("=== Arcilator PASS / Questa FAIL ===")
print("\n".join(arc_only) if arc_only else "(none)")

if fail_on_gaps and questa_only:
    sys.exit(1)
PY
