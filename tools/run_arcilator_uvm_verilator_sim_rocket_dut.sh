#!/usr/bin/env bash
set -euo pipefail

# Run arcilator in DUT mode on the subset of UVM-tagged tests that support
# `:type: simulation` (i.e. the ones a Verilator run would execute in simulation
# mode).
#
# Note: this intentionally disables the UVM M0 semantic gate in `tools/runner`
# since DUT-mode does not execute the class-based UVM testbench.

SVTESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OUT_DIR="${OUT_DIR:-"${SVTESTS_DIR}/out_arcilator_dut_uvm_verilator_sim"}"
RUNNER_KEY="arcilator"

WORKERS="${WORKERS:-"$(nproc)"}"
OVERRIDE_TEST_TIMEOUTS="${OVERRIDE_TEST_TIMEOUTS:-1800}"
KEEP_TMP="${KEEP_TMP:-0}"

export ARCILATOR_ARTIFACTS="${ARCILATOR_ARTIFACTS:-onfail}"
export OVERRIDE_TEST_TIMEOUTS

export ARCILATOR_UVM_TOP_MODE="${ARCILATOR_UVM_TOP_MODE:-dut}"
export SVTESTS_UVM_M0_ARCILATOR="${SVTESTS_UVM_M0_ARCILATOR:-0}"

tmp_tests_file="$(mktemp)"
cleanup() { rm -f "${tmp_tests_file}"; }
trap cleanup EXIT

TESTS_DIR="${SVTESTS_DIR}/tests" python3 - >"${tmp_tests_file}" <<'PY'
import os
import re
import sys
from pathlib import Path

tests_root = Path(os.environ["TESTS_DIR"])
tags_re = re.compile(r"^\s*:tags:\s*(.*?)\s*$", re.M)
type_re = re.compile(r"^\s*:type:\s*(.*?)\s*$", re.M)

selected = []
for p in tests_root.rglob("*"):
    if not p.is_file():
        continue
    if p.suffix.lower() not in (".sv", ".v", ".svh", ".vh"):
        continue
    try:
        head = p.read_text(encoding="utf-8", errors="ignore")[:20000]
    except OSError:
        continue

    m_tags = tags_re.search(head)
    if not m_tags:
        continue
    tags = set((m_tags.group(1) or "").split())
    if "uvm" not in tags:
        continue

    m_type = type_re.search(head)
    types = set((m_type.group(1) if m_type else "").split())
    if "simulation" not in types:
        continue

    selected.append(str(p.relative_to(tests_root)))

selected = sorted(set(selected))
sys.stderr.write(f"[select] uvm + type=simulation: {len(selected)} tests\n")
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

