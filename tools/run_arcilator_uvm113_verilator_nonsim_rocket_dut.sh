#!/usr/bin/env bash
set -euo pipefail

# Run arcilator in DUT mode on the subset of "UVM113" tests whose sv-tests
# metadata does NOT include `:type: simulation`.
#
# Note: this intentionally disables the UVM M0 semantic gate in `tools/runner`
# since DUT-mode does not execute the class-based UVM testbench.

SVTESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${DATA_DIR:-"${SVTESTS_DIR}/tools/data"}"
UVM113_LIST="${UVM113_LIST:-"${DATA_DIR}/uvm113_tests.txt"}"

OUT_DIR="${OUT_DIR:-"${SVTESTS_DIR}/out_arcilator_dut_uvm113_verilator_nonsim"}"
RUNNER_KEY="arcilator"

WORKERS="${WORKERS:-"$(nproc)"}"
OVERRIDE_TEST_TIMEOUTS="${OVERRIDE_TEST_TIMEOUTS:-1800}"
KEEP_TMP="${KEEP_TMP:-0}"

export ARCILATOR_ARTIFACTS="${ARCILATOR_ARTIFACTS:-onfail}"
export OVERRIDE_TEST_TIMEOUTS

export ARCILATOR_UVM_TOP_MODE="${ARCILATOR_UVM_TOP_MODE:-dut}"
export SVTESTS_UVM_M0_ARCILATOR="${SVTESTS_UVM_M0_ARCILATOR:-0}"

if [[ ! -f "${UVM113_LIST}" ]]; then
  echo "[error] missing UVM113_LIST=${UVM113_LIST}" >&2
  exit 2
fi

tmp_tests_file="$(mktemp)"
cleanup() { rm -f "${tmp_tests_file}"; }
trap cleanup EXIT

TESTS_DIR="${SVTESTS_DIR}/tests" UVM113_LIST="${UVM113_LIST}" python3 - >"${tmp_tests_file}" <<'PY'
import os
import re
import sys
from pathlib import Path

tests_root = Path(os.environ["TESTS_DIR"])
uvm113_list = Path(os.environ["UVM113_LIST"])

type_re = re.compile(r"^\s*:type:\s*(.*?)\s*$", re.M)

selected = []
missing = 0
for raw in uvm113_list.read_text(encoding="utf-8", errors="ignore").splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    p = tests_root / line
    if not p.is_file():
        missing += 1
        continue
    head = p.read_text(encoding="utf-8", errors="ignore")[:20000]
    m_type = type_re.search(head)
    types = set((m_type.group(1) if m_type else "").split())
    if "simulation" not in types:
        selected.append(line)

selected = sorted(set(selected))
sys.stderr.write(f"[select] uvm113 (list={uvm113_list}) missing={missing} mode!=simulation: {len(selected)} tests\n")
for rel in selected:
    print(rel)
PY

num_tests="$(wc -l <"${tmp_tests_file}" | tr -d '[:space:]')"
echo "[run] ${RUNNER_KEY} on ${num_tests} tests (WORKERS=${WORKERS})"
echo "[out] ${OUT_DIR}"

mkdir -p "${OUT_DIR}/logs/${RUNNER_KEY}" "${OUT_DIR}/report"
cp -f "${tmp_tests_file}" "${OUT_DIR}/selected_tests.txt"

export OUT_DIR
export CONF_DIR="${SVTESTS_DIR}/conf"
export TESTS_DIR="${SVTESTS_DIR}/tests"
export RUNNERS_DIR="${SVTESTS_DIR}/tools/runners"
export THIRD_PARTY_DIR="${SVTESTS_DIR}/third_party"
export GENERATORS_DIR="${SVTESTS_DIR}/generators"

runner_param="--quiet"
if [[ "${KEEP_TMP}" != "0" && "${KEEP_TMP}" != "false" && "${KEEP_TMP}" != "no" && "${KEEP_TMP}" != "off" ]]; then
  runner_param="--keep-tmp"
fi

export RUNNER_KEY SVTESTS_DIR runner_param
cat "${tmp_tests_file}" | xargs -P "${WORKERS}" -n 1 bash -lc '
set -euo pipefail
t="$1"
out="${OUT_DIR}/logs/${RUNNER_KEY}/${t}.log"
"${SVTESTS_DIR}/tools/runner" --runner "${RUNNER_KEY}" --test "${t}" --out "${out}" "${runner_param}"
' _ || true

rev="$(git -C "${SVTESTS_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
(cd "${SVTESTS_DIR}" && python3 tools/sv-report \
  --revision "${rev}" \
  --logs "${OUT_DIR}/logs" \
  --out "${OUT_DIR}/report/index.html" \
  --csv "${OUT_DIR}/report/report.csv")
cp -f "${SVTESTS_DIR}/conf/report/"*.css "${OUT_DIR}/report/"
cp -f "${SVTESTS_DIR}/conf/report/"*.js "${OUT_DIR}/report/"
cp -f "${SVTESTS_DIR}/conf/report/"*.png "${OUT_DIR}/report/" || true
cp -f "${SVTESTS_DIR}/conf/report/"*.svg "${OUT_DIR}/report/" || true

python3 - "${OUT_DIR}/report/report.csv" <<'PY'
import csv
import sys

path = sys.argv[1]
rows = list(csv.DictReader(open(path, newline="")))
passed = sum(1 for r in rows if r.get("Pass") == "True")
print(f"[summary] PASS {passed}/{len(rows)}  (csv={path})")
PY

echo "[ok] done"

