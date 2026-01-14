#!/usr/bin/env bash
set -euo pipefail

# Run arcilator in top-executed mode (`RUNNERS=arcilator_top`) on every test
# named in `chipsalliance.csv` (unique TestName values that can be mapped to
# local sv-tests sources).

SVTESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CHIPSALLIANCE_CSV="${CHIPSALLIANCE_CSV:-}"
if [[ -z "${CHIPSALLIANCE_CSV}" ]]; then
  if [[ -f "${SVTESTS_DIR}/chipsalliance.csv" ]]; then
    CHIPSALLIANCE_CSV="${SVTESTS_DIR}/chipsalliance.csv"
  elif [[ -f "${SVTESTS_DIR}/../chipsalliance.csv" ]]; then
    CHIPSALLIANCE_CSV="${SVTESTS_DIR}/../chipsalliance.csv"
  fi
fi
if [[ ! -f "${CHIPSALLIANCE_CSV}" ]]; then
  echo "[error] missing CHIPSALLIANCE_CSV (set env var) (tried: ${SVTESTS_DIR}/chipsalliance.csv, ${SVTESTS_DIR}/../chipsalliance.csv)" >&2
  exit 2
fi

OUT_DIR="${OUT_DIR:-"${SVTESTS_DIR}/out_arcilator_top_chipsalliance_all"}"
RUNNER_KEY="arcilator_top"

WORKERS="${WORKERS:-"$(nproc)"}"
OVERRIDE_TEST_TIMEOUTS="${OVERRIDE_TEST_TIMEOUTS:-1800}"
KEEP_TMP="${KEEP_TMP:-0}"

export ARCILATOR_ARTIFACTS="${ARCILATOR_ARTIFACTS:-onfail}"
export OVERRIDE_TEST_TIMEOUTS

tmp_tests_file="$(mktemp)"
cleanup() { rm -f "${tmp_tests_file}"; }
trap cleanup EXIT

TESTS_DIR="${SVTESTS_DIR}/tests" CHIPSALLIANCE_CSV="${CHIPSALLIANCE_CSV}" python3 - >"${tmp_tests_file}" <<'PY'
import csv
import os
import re
import sys
from pathlib import Path

tests_root = Path(os.environ["TESTS_DIR"])
chips = Path(os.environ["CHIPSALLIANCE_CSV"])

names = set()
with chips.open(newline="") as f:
    for row in csv.DictReader(f):
        name = (row.get("TestName") or "").strip()
        if name:
            names.add(name)

name_re = re.compile(r"^\s*:name:\s*(.*?)\s*$", re.M)
name_to_rel = {}
for p in tests_root.rglob("*"):
    if not p.is_file():
        continue
    if p.suffix.lower() not in (".sv", ".v", ".svh", ".vh"):
        continue
    try:
        head = p.read_text(encoding="utf-8", errors="ignore")[:20000]
    except OSError:
        continue
    m = name_re.search(head)
    if not m:
        continue
    name_to_rel.setdefault(m.group(1).strip(), str(p.relative_to(tests_root)))

selected = []
missing = 0
for n in sorted(names):
    rel = name_to_rel.get(n)
    if not rel:
        missing += 1
        continue
    selected.append(rel)

selected = sorted(set(selected))
sys.stderr.write(f"[select] chipsalliance names={len(names)} mapped={len(selected)} missing={missing}\n")
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
