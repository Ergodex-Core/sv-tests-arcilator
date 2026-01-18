#!/usr/bin/env bash
set -euo pipefail

SVTESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CALLER_PWD="$(pwd)"

usage() {
  cat <<'EOF'
usage: regenerate_questa_gold_vcd.sh [options]

Re-generates Questa gold VCDs for a list of UVM simulation testbenches by
forcing the simulation to run until (at least) a specified end time.

This relies on the sv-tests `Questa_vcd` runner and requires Questa tools to be
available in PATH: `vlog`, `vsim`, `vlib`.

Options:
  --list PATH           File with sv-tests test paths (required)
  --out-gold DIR        Output gold root (<stem>/wave.vcd) (required)
  --base-gold DIR       Existing gold root used to size the new run (default: sv-tests/gold/questa_vcd_uvm138_m0_fixedmarker)
  --min-endtime N       Minimum absolute end time to run to (default: 1000)
  --endtime-slack N     Add N time units to computed end time (default: 1)
  --multiplier K        Multiply base gold end time by K (default: 1)
  --out OUT_DIR         sv-tests OUT_DIR for logs/tmp (default: out_regen_questa_gold_<list>)
  --workers N           Parallelism (default: 1)
  --keep-tmp            Pass --keep-tmp to sv-tests/tools/runner
  --no-generate         Do not auto-run template generator if tests/generated missing
  -h, --help            Show help

Notes:
  - Uses SVTESTS_UVM_FORCE_RUN_UNTIL to disable UVM's default "$finish on phases done"
    and to call $finish at the computed absolute time. This keeps runs bounded.
EOF
}

LIST_PATH=""
OUT_GOLD_ROOT=""
BASE_GOLD_ROOT="${BASE_GOLD_ROOT:-"${SVTESTS_DIR}/gold/questa_vcd_uvm138_m0_fixedmarker"}"
MIN_ENDTIME="${MIN_ENDTIME:-1000}"
ENDTIME_SLACK="${ENDTIME_SLACK:-1}"
MULTIPLIER="${MULTIPLIER:-1}"
OUT_DIR=""
WORKERS="${WORKERS:-1}"
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
    --list)
      LIST_PATH="${2:-}"
      shift 2
      ;;
    --out-gold)
      OUT_GOLD_ROOT="${2:-}"
      shift 2
      ;;
    --base-gold)
      BASE_GOLD_ROOT="${2:-}"
      shift 2
      ;;
    --min-endtime)
      MIN_ENDTIME="${2:-}"
      shift 2
      ;;
    --endtime-slack)
      ENDTIME_SLACK="${2:-}"
      shift 2
      ;;
    --multiplier)
      MULTIPLIER="${2:-}"
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

if [[ -z "${LIST_PATH}" || -z "${OUT_GOLD_ROOT}" ]]; then
  echo "[error] missing --list and/or --out-gold" >&2
  usage >&2
  exit 2
fi

if [[ "${LIST_PATH}" != /* ]]; then
  LIST_PATH="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "${CALLER_PWD}/${LIST_PATH}")"
fi
if [[ "${OUT_GOLD_ROOT}" != /* ]]; then
  OUT_GOLD_ROOT="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "${CALLER_PWD}/${OUT_GOLD_ROOT}")"
fi
if [[ "${BASE_GOLD_ROOT}" != /* ]]; then
  BASE_GOLD_ROOT="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "${CALLER_PWD}/${BASE_GOLD_ROOT}")"
fi

if [[ ! -f "${LIST_PATH}" ]]; then
  echo "[error] missing list: ${LIST_PATH}" >&2
  exit 2
fi
if [[ ! -d "${SVTESTS_DIR}" ]]; then
  echo "[error] sv-tests dir missing: ${SVTESTS_DIR}" >&2
  exit 2
fi
if ! [[ "${MIN_ENDTIME}" =~ ^[0-9]+$ ]] || [[ "${MIN_ENDTIME}" -le 0 ]]; then
  echo "[error] --min-endtime must be a positive integer: ${MIN_ENDTIME}" >&2
  exit 2
fi
if ! [[ "${ENDTIME_SLACK}" =~ ^[0-9]+$ ]]; then
  echo "[error] --endtime-slack must be a non-negative integer: ${ENDTIME_SLACK}" >&2
  exit 2
fi
if ! [[ "${MULTIPLIER}" =~ ^[0-9]+$ ]] || [[ "${MULTIPLIER}" -lt 1 ]]; then
  echo "[error] --multiplier must be an integer >= 1: ${MULTIPLIER}" >&2
  exit 2
fi

if [[ -n "${QUESTA_BIN_DIR:-}" ]]; then
  export PATH="${QUESTA_BIN_DIR}:${PATH}"
else
  workspace_dir="$(cd "${SVTESTS_DIR}/.." && pwd)"
  maybe_bin="${workspace_dir}/questa/questa_fse/linux_x86_64"
  if [[ -d "${maybe_bin}" ]]; then
    export PATH="${maybe_bin}:${PATH}"
  fi
fi

if [[ -z "${SALT_LICENSE_SERVER:-}" ]]; then
  maybe_license="${workspace_dir:-"$(cd "${SVTESTS_DIR}/.." && pwd)"}/LR-277765_License.dat"
  if [[ -f "${maybe_license}" ]]; then
    export SALT_LICENSE_SERVER="${maybe_license}"
  fi
fi

for tool in vlog vsim vlib; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "[error] required Questa tool not found in PATH: ${tool}" >&2
    exit 2
  fi
done

list_base="$(basename "${LIST_PATH}")"
list_base="${list_base%.*}"
if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="${SVTESTS_DIR}/out_regen_questa_gold_${list_base}"
fi
if [[ "${OUT_DIR}" != /* ]]; then
  OUT_DIR="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "${CALLER_PWD}/${OUT_DIR}")"
fi

if [[ ! -d "${SVTESTS_DIR}/tests/generated" && "${AUTO_GENERATE}" != "0" && "${AUTO_GENERATE}" != "false" && "${AUTO_GENERATE}" != "no" && "${AUTO_GENERATE}" != "off" ]]; then
  echo "[info] tests/generated missing; running template generator"
  make -C "${SVTESTS_DIR}" generate-template_generator -j"$(nproc)"
fi

mkdir -p "${OUT_GOLD_ROOT}" "${OUT_DIR}/logs/questa_vcd"

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

export OUT_DIR
export CONF_DIR="${SVTESTS_DIR}/conf"
export TESTS_DIR="${SVTESTS_DIR}/tests"
export RUNNERS_DIR="${SVTESTS_DIR}/tools/runners"
export THIRD_PARTY_DIR="${SVTESTS_DIR}/third_party"
export GENERATORS_DIR="${SVTESTS_DIR}/generators"
export OVERRIDE_TEST_TIMEOUTS="${OVERRIDE_TEST_TIMEOUTS:-1800}"

export QUESTA_ARTIFACTS="vcd"
export QUESTA_ARTIFACT_ROOT="${OUT_GOLD_ROOT}"

runner_param="--quiet"
if [[ "${KEEP_TMP}" != "0" && "${KEEP_TMP}" != "false" && "${KEEP_TMP}" != "no" && "${KEEP_TMP}" != "off" ]]; then
  runner_param="--keep-tmp"
fi
export SVTESTS_DIR runner_param

python3 - "${tmp_tests_file}" "${BASE_GOLD_ROOT}" "${MIN_ENDTIME}" "${ENDTIME_SLACK}" "${MULTIPLIER}" >"${tmp_run_file}" <<'PY'
import sys
from pathlib import Path

tests_file = Path(sys.argv[1])
base_root = Path(sys.argv[2])
min_end = int(sys.argv[3])
slack = int(sys.argv[4])
mult = int(sys.argv[5])

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
    vcd = base_root / stem / "wave.vcd"
    base_last = last_change_timestamp(vcd) if vcd.is_file() else 0
    target = max(min_end, base_last * mult) + slack
    if target <= 0:
        target = min_end
    print(f"{target}\t{test_rel}")
PY

cp -f "${tmp_tests_file}" "${OUT_DIR}/selected_tests.txt"
cp -f "${tmp_run_file}" "${OUT_DIR}/force_run_until.tsv"

cat "${tmp_run_file}" | xargs -P "${WORKERS}" -n 2 bash -lc '
set -euo pipefail
force_until="$1"
t="$2"
out="${OUT_DIR}/logs/questa_vcd/${t}.log"
mkdir -p "$(dirname "${out}")"
SVTESTS_UVM_FORCE_RUN_UNTIL="${force_until}" "${SVTESTS_DIR}/tools/runner" --runner Questa_vcd --test "${t}" --out "${out}" "${runner_param}"
' _

echo "[done] gold_root=${OUT_GOLD_ROOT}"
echo "[done] logs_out=${OUT_DIR}"
