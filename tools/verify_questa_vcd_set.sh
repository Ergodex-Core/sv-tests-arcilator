#!/usr/bin/env bash
set -euo pipefail

SVTESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CALLER_PWD="$(pwd)"

usage() {
  cat <<'EOF'
usage: verify_questa_vcd_set.sh [options]

Runs arcilator (default: RUNNER=arcilator_top) on a test list and diffs the
generated Arcilator VCDs against *stored* Questa gold VCDs tracked in git.

This script never runs Questa.

Options:
  --list PATH         File with sv-tests test paths (required)
  --gold-root PATH    Root directory containing <stem>/wave.vcd (required)
  --arcilator-vcd-dt N  Set ARCILATOR_VCD_DT (default: 1)
  --runner RUNNER     sv-tests runner key (default: arcilator_top)
  --top1 PATH         Instance prefix in gold VCD (default: top)
  --top2 PATH         Instance prefix in arcilator VCD (default: top.internal)
  --out OUT_DIR       Output dir (default: out_vcd_vs_gold_<runner>_<list>)
  --workers N         Parallelism for running tests (default: nproc)
  --keep-tmp          Pass --keep-tmp to sv-tests/tools/runner
  --skip-run          Do not run arcilator; only diff existing artifacts
  --no-generate       Do not auto-run template generator if tests/generated missing
  -h, --help          Show this help

Environment:
  ARCILATOR_ARTIFACTS is forced to "always" for VCD capture.
EOF
}

LIST_PATH=""
GOLD_ROOT=""
RUNNER_KEY="${RUNNER_KEY:-arcilator_top}"
TOP1="${TOP1:-top}"
TOP2="${TOP2:-top.internal}"
ARCILATOR_VCD_DT="${ARCILATOR_VCD_DT:-1}"
OUT_DIR=""
WORKERS="${WORKERS:-"$(nproc)"}"
KEEP_TMP="${KEEP_TMP:-0}"
SKIP_RUN="${SKIP_RUN:-0}"
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
    --list)
      LIST_PATH="${2:-}"
      shift 2
      ;;
    --gold-root)
      GOLD_ROOT="${2:-}"
      shift 2
      ;;
    --arcilator-vcd-dt)
      ARCILATOR_VCD_DT="${2:-}"
      shift 2
      ;;
    --runner)
      RUNNER_KEY="${2:-}"
      shift 2
      ;;
    --top1)
      TOP1="${2:-}"
      shift 2
      ;;
    --top2)
      TOP2="${2:-}"
      shift 2
      ;;
    --out)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    --workers)
      WORKERS="${2:-}"
      shift 2
      ;;
    --keep-tmp)
      KEEP_TMP=1
      shift
      ;;
    --skip-run)
      SKIP_RUN=1
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
    *)
      echo "[error] unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${LIST_PATH}" || -z "${GOLD_ROOT}" ]]; then
  echo "[error] missing --list and/or --gold-root" >&2
  usage >&2
  exit 2
fi

if [[ "${LIST_PATH}" != /* ]]; then
  LIST_PATH="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "${CALLER_PWD}/${LIST_PATH}")"
fi
if [[ "${GOLD_ROOT}" != /* ]]; then
  GOLD_ROOT="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "${CALLER_PWD}/${GOLD_ROOT}")"
fi
if [[ ! -f "${LIST_PATH}" ]]; then
  echo "[error] missing list: ${LIST_PATH}" >&2
  exit 2
fi
if [[ ! -d "${GOLD_ROOT}" ]]; then
  echo "[error] missing gold root dir: ${GOLD_ROOT}" >&2
  exit 2
fi
if ! [[ "${ARCILATOR_VCD_DT}" =~ ^[0-9]+$ ]] || [[ "${ARCILATOR_VCD_DT}" -le 0 ]]; then
  echo "[error] invalid --arcilator-vcd-dt (expected positive integer): ${ARCILATOR_VCD_DT}" >&2
  exit 2
fi

sanitize_stem() {
  python3 - "$1" <<'PY'
import os
import re
import sys

text = sys.argv[1]
text = text.replace(os.sep, "__")
text = re.sub(r"[^a-zA-Z0-9_.-]+", "_", text)
text = text.strip("._-") or "unnamed"
print(text)
PY
}

is_should_fail() {
  python3 - "${SVTESTS_DIR}" "$1" <<'PY'
import re
import sys
from pathlib import Path

svtests_dir = Path(sys.argv[1])
test_rel = sys.argv[2]
test_path = svtests_dir / "tests" / test_rel

meta_re = re.compile(r"^:([a-zA-Z_-]+):\s*(.+)$")
meta = {}
try:
    for line in test_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        m = meta_re.match(line)
        if not m:
            continue
        meta[m.group(1).lower()] = m.group(2).strip()
except OSError:
    sys.exit(1)

should_fail = meta.get("should_fail", "0").strip() == "1" or "should_fail_because" in meta
sys.exit(0 if should_fail else 1)
PY
}

list_base="$(basename "${LIST_PATH}")"
list_base="${list_base%.*}"
if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="${SVTESTS_DIR}/out_vcd_vs_gold_${RUNNER_KEY}_${list_base}"
fi

if [[ "${OUT_DIR}" != /* ]]; then
  OUT_DIR="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "${CALLER_PWD}/${OUT_DIR}")"
fi

if [[ ! -d "${SVTESTS_DIR}/tests/generated" && "${AUTO_GENERATE}" != "0" && "${AUTO_GENERATE}" != "false" && "${AUTO_GENERATE}" != "no" && "${AUTO_GENERATE}" != "off" ]]; then
  echo "[info] tests/generated missing; running template generator"
  make -C "${SVTESTS_DIR}" generate-template_generator -j"$(nproc)"
fi

tmp_tests_file="$(mktemp)"
tmp_run_file="$(mktemp)"
cleanup() { rm -f "${tmp_tests_file}" "${tmp_run_file}"; }
trap cleanup EXIT

TESTS_DIR="${SVTESTS_DIR}/tests" LIST_PATH="${LIST_PATH}" python3 - >"${tmp_tests_file}" <<'PY'
import os
import sys
from pathlib import Path

tests_root = Path(os.environ["TESTS_DIR"])
list_path = Path(os.environ["LIST_PATH"])

selected = []
missing = 0
for raw in list_path.read_text(encoding="utf-8", errors="ignore").splitlines():
    rel = raw.strip()
    if not rel or rel.startswith("#"):
        continue
    if not (tests_root / rel).is_file():
        missing += 1
        continue
    selected.append(rel)

selected = sorted(dict.fromkeys(selected))
sys.stderr.write(f"[select] list={list_path} mapped={len(selected)} missing={missing}\n")
for rel in selected:
    print(rel)
PY

num_tests="$(wc -l <"${tmp_tests_file}" | tr -d '[:space:]')"
echo "[list] ${LIST_PATH}"
echo "[gold] ${GOLD_ROOT}"
echo "[arcilator] vcd_dt=${ARCILATOR_VCD_DT}"
echo "[run] runner=${RUNNER_KEY} tests=${num_tests} workers=${WORKERS}"
echo "[out] ${OUT_DIR}"

mkdir -p "${OUT_DIR}/logs/${RUNNER_KEY}" "${OUT_DIR}/report" "${OUT_DIR}/diffs"
cp -f "${tmp_tests_file}" "${OUT_DIR}/selected_tests.txt"

export OUT_DIR
export CONF_DIR="${SVTESTS_DIR}/conf"
export TESTS_DIR="${SVTESTS_DIR}/tests"
export RUNNERS_DIR="${SVTESTS_DIR}/tools/runners"
export THIRD_PARTY_DIR="${SVTESTS_DIR}/third_party"
export GENERATORS_DIR="${SVTESTS_DIR}/generators"
export OVERRIDE_TEST_TIMEOUTS="${OVERRIDE_TEST_TIMEOUTS:-1800}"

export ARCILATOR_ARTIFACTS="always"
export ARCILATOR_VCD_DT
export ARCILATOR_SIM_DT_FS="$((ARCILATOR_VCD_DT * 1000000))"
export SVTESTS_UVM_FORCE_RUN_UNTIL="${SVTESTS_UVM_FORCE_RUN_UNTIL:-0}"

runner_param="--quiet"
if [[ "${KEEP_TMP}" != "0" && "${KEEP_TMP}" != "false" && "${KEEP_TMP}" != "no" && "${KEEP_TMP}" != "off" ]]; then
  runner_param="--keep-tmp"
fi

export RUNNER_KEY SVTESTS_DIR runner_param

# Pre-compute per-test ARCILATOR_CYCLES from the stored gold VCD length.
python3 - "${tmp_tests_file}" "${GOLD_ROOT}" "${ARCILATOR_VCD_DT}" >"${tmp_run_file}" <<'PY'
import sys
from pathlib import Path

tests_file = Path(sys.argv[1])
gold_root = Path(sys.argv[2])
dt = int(sys.argv[3])

def last_change_timestamp(vcd: Path) -> int:
    cur_t = 0
    last_change_t = 0
    with vcd.open("r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            if not line:
                continue
            if line.startswith("#"):
                try:
                    cur_t = int(line[1:].strip() or "0")
                except ValueError:
                    continue
                continue
            if line.startswith("$"):
                continue
            if line[:1] and line[0] in "01xXzZbBrRsS":
                last_change_t = cur_t
    return last_change_t

for raw in tests_file.read_text(encoding="utf-8", errors="ignore").splitlines():
    test_rel = raw.strip()
    if not test_rel:
        continue
    stem = test_rel.replace("/", "__")
    vcd = gold_root / stem / "wave.vcd"
    cycles = 1
    if vcd.is_file():
        last = last_change_timestamp(vcd)
        cycles = max((last + dt - 1) // dt, 1)
    print(f"{cycles}\t{test_rel}")
PY
cp -f "${tmp_run_file}" "${OUT_DIR}/arcilator_cycles.tsv"

skip_run_truthy=0
if [[ "${SKIP_RUN}" != "0" && "${SKIP_RUN}" != "false" && "${SKIP_RUN}" != "no" && "${SKIP_RUN}" != "off" && "${SKIP_RUN}" != "" ]]; then
  skip_run_truthy=1
fi

if [[ "${skip_run_truthy}" -eq 0 ]]; then
  cat "${tmp_run_file}" | xargs -P "${WORKERS}" -n 2 bash -lc '
set -euo pipefail
cycles="$1"
t="$2"
out="${OUT_DIR}/logs/${RUNNER_KEY}/${t}.log"
mkdir -p "$(dirname "${out}")"
ARCILATOR_CYCLES="${cycles}" "${SVTESTS_DIR}/tools/runner" --runner "${RUNNER_KEY}" --test "${t}" --out "${out}" "${runner_param}"
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
fi

match=0
mismatch=0
no_common=0
missing_arc=0
missing_gold=0
skipped_expected=0

while IFS= read -r t; do
  stem="$(sanitize_stem "${t}")"
  gold_vcd="${GOLD_ROOT}/${stem}/wave.vcd"
  arc_vcd="${OUT_DIR}/artifacts/arcilator/${stem}/wave.vcd"
  diff_out="${OUT_DIR}/diffs/${stem}.diff"

  if [[ ! -f "${gold_vcd}" ]]; then
    if is_should_fail "${t}"; then
      echo "[skip] no gold VCD (expected compile-fail): ${t}"
      skipped_expected=$((skipped_expected+1))
      continue
    fi
    echo "[nogold] ${t} (expected ${gold_vcd})"
    missing_gold=$((missing_gold+1))
    continue
  fi

  if [[ ! -f "${arc_vcd}" ]]; then
    echo "[missing] arcilator VCD not found: ${t} (expected ${arc_vcd})"
    missing_arc=$((missing_arc+1))
    continue
  fi

  set +e
  python3 "${SVTESTS_DIR}/tools/vcd_diff.py" "${gold_vcd}" "${arc_vcd}" --top1 "${TOP1}" --top2 "${TOP2}" >"${diff_out}" 2>&1
  rc=$?
  set -e
  if [[ ${rc} -eq 0 ]]; then
    echo "[match] ${t}"
    match=$((match+1))
    rm -f "${diff_out}" || true
  elif [[ ${rc} -eq 2 ]]; then
    echo "[no-common] ${t}"
    no_common=$((no_common+1))
  else
    echo "[mismatch] ${t}"
    mismatch=$((mismatch+1))
    cat "${diff_out}"
  fi
done <"${tmp_tests_file}"

total="${num_tests}"
echo "[summary] total=${total} match=${match} mismatch=${mismatch} no_common=${no_common} missing_arc=${missing_arc} missing_gold=${missing_gold} skipped_expected=${skipped_expected}"

if [[ "${mismatch}" -ne 0 || "${missing_arc}" -ne 0 || "${missing_gold}" -ne 0 ]]; then
  exit 1
fi
exit 0
