#!/usr/bin/env bash
set -euo pipefail

SVTESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_ROOT="$(cd "${SVTESTS_DIR}/.." && pwd)"
CALLER_PWD="$(pwd)"

usage() {
  cat <<'EOF'
usage: run_chipsalliance_test.sh [options] <TestName>

Runs a local sv-tests test selected by Chips Alliance CSV `TestName` (maps
`TestName` → `sv-tests/tests/...` by scanning `:name:` metadata).

Options:
  --csv PATH          Path to chipsalliance.csv (default: ./chipsalliance.csv)
  --runner RUNNER     sv-tests runner key (default: arcilator_top)
  --out OUT_DIR       Output dir (default: out_chipsalliance_<runner>_<name>)
  --keep-tmp          Pass --keep-tmp to sv-tests/tools/runner
  --no-generate       Do not auto-run template generator if tests/generated missing
  -h, --help          Show this help

Examples:
  ./tools/run_chipsalliance_test.sh assert_test_uvm
  ./tools/run_chipsalliance_test.sh --runner Verilator_vcd assert_test_uvm
  ./tools/run_chipsalliance_test.sh easyUVM
EOF
}

CHIPSALLIANCE_CSV="${CHIPSALLIANCE_CSV:-}"
RUNNER_KEY="${RUNNER_KEY:-arcilator_top}"
OUT_DIR="${OUT_DIR:-}"
KEEP_TMP="${KEEP_TMP:-0}"
AUTO_GENERATE="${AUTO_GENERATE:-1}"

if [[ ${#} -eq 0 ]]; then
  usage
  exit 2
fi

while [[ ${#} -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --csv)
      CHIPSALLIANCE_CSV="${2:-}"
      shift 2
      ;;
    --runner)
      RUNNER_KEY="${2:-}"
      shift 2
      ;;
    --out)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    --keep-tmp)
      KEEP_TMP=1
      shift
      ;;
    --no-generate)
      AUTO_GENERATE=0
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "[error] unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

TEST_NAME="${1:-}"
if [[ -z "${TEST_NAME}" ]]; then
  echo "[error] missing <TestName>" >&2
  usage >&2
  exit 2
fi

if [[ -z "${CHIPSALLIANCE_CSV}" ]]; then
  if [[ -f "${SVTESTS_DIR}/chipsalliance.csv" ]]; then
    CHIPSALLIANCE_CSV="${SVTESTS_DIR}/chipsalliance.csv"
  elif [[ -f "${WS_ROOT}/chipsalliance.csv" ]]; then
    CHIPSALLIANCE_CSV="${WS_ROOT}/chipsalliance.csv"
  fi
fi
if [[ ! -f "${CHIPSALLIANCE_CSV}" ]]; then
  echo "[error] missing CHIPSALLIANCE_CSV (set --csv or env var) (tried: ${SVTESTS_DIR}/chipsalliance.csv, ${WS_ROOT}/chipsalliance.csv)" >&2
  exit 2
fi

sanitize() {
  # shellcheck disable=SC2001
  echo "$1" | sed -E 's/[^a-zA-Z0-9_.-]+/_/g' | sed -E 's/^[_\\.-]+|[_\\.-]+$//g'
}

safe_name="$(sanitize "${TEST_NAME}")"
if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="${SVTESTS_DIR}/out_chipsalliance_${RUNNER_KEY}_${safe_name}"
fi
if [[ "${OUT_DIR}" != /* ]]; then
  OUT_DIR="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "${CALLER_PWD}/${OUT_DIR}")"
fi

if [[ ! -d "${SVTESTS_DIR}/tests/generated" && "${AUTO_GENERATE}" != "0" && "${AUTO_GENERATE}" != "false" && "${AUTO_GENERATE}" != "no" && "${AUTO_GENERATE}" != "off" ]]; then
  echo "[info] tests/generated missing; running template generator"
  make -C "${SVTESTS_DIR}" generate-template_generator -j"$(nproc)"
fi

test_rel="$(
  python3 - "${SVTESTS_DIR}" "${CHIPSALLIANCE_CSV}" "${TEST_NAME}" <<'PY'
import csv
import difflib
import os
import re
import sys
from pathlib import Path

sv_tests_dir = Path(sys.argv[1]).resolve()
chips_csv = Path(sys.argv[2]).resolve()
test_name = sys.argv[3].strip()

rows = []
with chips_csv.open(newline="") as f:
    for row in csv.DictReader(f):
        if (row.get("TestName") or "").strip() == test_name:
            rows.append(row)

if not rows:
    sys.stderr.write(f"[csv] warning: TestName not found in {chips_csv}: {test_name}\n")
else:
    sys.stderr.write(f"[csv] {test_name}: {len(rows)} row(s)\n")
    for r in sorted(rows, key=lambda x: (x.get("Tool") or "")):
        tool = (r.get("Tool") or "").strip()
        passed = (r.get("Pass") or "").strip()
        exit_code = (r.get("ExitCode") or "").strip()
        tags = (r.get("Tags") or "").strip()
        sys.stderr.write(f"  Tool={tool} Pass={passed} ExitCode={exit_code} Tags={tags}\n")

tests_root = sv_tests_dir / "tests"
name_re = re.compile(r"^ *:name: *(.*?) *$", re.M)
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

# Known chipsalliance.csv → local sv-tests name skew.
overrides = {
    "property_disable_iff_fail_test_uvm": "chapter-16/16.15--property-iff-uvm-fail.sv",
}

rel = name_to_rel.get(test_name) or overrides.get(test_name)
if not rel:
    sys.stderr.write(f"[error] no sv-tests source found for TestName={test_name}\n")
    close = difflib.get_close_matches(test_name, sorted(name_to_rel.keys()), n=10, cutoff=0.60)
    if close:
        sys.stderr.write("[hint] close matches:\n")
        for c in close:
            sys.stderr.write(f"  {c}\n")
    sys.exit(3)

print(rel)
PY
)"

echo "[map] ${TEST_NAME} -> ${test_rel}"
echo "[run] runner=${RUNNER_KEY}"
echo "[csv] ${CHIPSALLIANCE_CSV}"
echo "[out] ${OUT_DIR}"

mkdir -p "${OUT_DIR}/logs/${RUNNER_KEY}" "${OUT_DIR}/report"

export OUT_DIR
export CONF_DIR="${SVTESTS_DIR}/conf"
export TESTS_DIR="${SVTESTS_DIR}/tests"
export RUNNERS_DIR="${SVTESTS_DIR}/tools/runners"
export THIRD_PARTY_DIR="${SVTESTS_DIR}/third_party"
export GENERATORS_DIR="${SVTESTS_DIR}/generators"
export ARCILATOR_ARTIFACTS="${ARCILATOR_ARTIFACTS:-onfail}"

export OVERRIDE_TEST_TIMEOUTS="${OVERRIDE_TEST_TIMEOUTS:-1800}"

runner_param="--quiet"
if [[ "${KEEP_TMP}" != "0" && "${KEEP_TMP}" != "false" && "${KEEP_TMP}" != "no" && "${KEEP_TMP}" != "off" ]]; then
  runner_param="--keep-tmp"
fi

log_path="${OUT_DIR}/logs/${RUNNER_KEY}/${test_rel}.log"
mkdir -p "$(dirname "${log_path}")"

"${SVTESTS_DIR}/tools/runner" --runner "${RUNNER_KEY}" --test "${test_rel}" --out "${log_path}" "${runner_param}"

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

python3 - "${OUT_DIR}/report/report.csv" "${TEST_NAME}" "${RUNNER_KEY}" <<'PY'
import csv
import sys

csv_path, test_name, runner = sys.argv[1:]
rows = list(csv.DictReader(open(csv_path, newline="")))
if not rows:
    print(f"[error] empty report: {csv_path}", file=sys.stderr)
    sys.exit(2)

passed = sum(1 for r in rows if r.get("Pass") == "True")
print(f"[summary] PASS {passed}/{len(rows)}  (csv={csv_path})")

row = rows[0]
row_pass = row.get("Pass") == "True"
status = "PASS" if row_pass else "FAIL"
print(f"[result] {status}: {test_name} (runner={runner})")
sys.exit(0 if row_pass else 1)
PY
