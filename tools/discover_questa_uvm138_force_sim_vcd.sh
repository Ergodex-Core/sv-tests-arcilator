#!/usr/bin/env bash
set -euo pipefail

SVTESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CALLER_PWD="$(pwd)"

usage() {
  cat <<'EOF'
usage: discover_questa_uvm138_force_sim_vcd.sh [options]

Forces sv-tests tests to run in Questa simulation mode (without editing the
test sources) and reports how many produce a valid, non-empty VCD.

This is intended to answer: "what's the maximal UVM138 subset that can produce
meaningful Questa VCDs worth targeting for Arcilator parity?"

Options:
  --list PATH           Test list (default: tools/data/uvm138_tests.txt)
  --out OUT_DIR         Output dir (default: out_discover_questa_uvm138_force_sim_vcd)
  --workers N           Parallelism (default: nproc)
  --force-until N       SVTESTS_UVM_FORCE_RUN_UNTIL (default: 1001)
  --keep-tmp            Keep per-test tmp dirs (slow/large; default: off)
  --no-generate         Do not auto-run template generator if tests/generated missing
  -h, --help            Show help

Outputs (under OUT_DIR):
  - artifacts/questa_vcd/<stem>/wave.vcd
  - logs/questa_vcd/<test>.log
  - vcd_ok_tests.txt (tests with valid VCD)
  - summary.txt
EOF
}

LIST_PATH="${LIST_PATH:-"${SVTESTS_DIR}/tools/data/uvm138_tests.txt"}"
OUT_DIR="${OUT_DIR:-"${SVTESTS_DIR}/out_discover_questa_uvm138_force_sim_vcd"}"
WORKERS="${WORKERS:-"$(nproc)"}"
FORCE_UNTIL="${FORCE_UNTIL:-1001}"
KEEP_TMP="${KEEP_TMP:-0}"
AUTO_GENERATE="${AUTO_GENERATE:-1}"

if [[ ${#} -gt 0 ]]; then
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
      --out)
        OUT_DIR="${2:-}"
        shift 2
        ;;
      --workers)
        WORKERS="${2:-}"
        shift 2
        ;;
      --force-until)
        FORCE_UNTIL="${2:-}"
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
fi

if [[ "${LIST_PATH}" != /* ]]; then
  LIST_PATH="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "${CALLER_PWD}/${LIST_PATH}")"
fi
if [[ "${OUT_DIR}" != /* ]]; then
  OUT_DIR="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "${CALLER_PWD}/${OUT_DIR}")"
fi

if [[ ! -f "${LIST_PATH}" ]]; then
  echo "[error] missing list: ${LIST_PATH}" >&2
  exit 2
fi
if ! [[ "${FORCE_UNTIL}" =~ ^[0-9]+$ ]] || [[ "${FORCE_UNTIL}" -le 0 ]]; then
  echo "[error] --force-until must be a positive integer: ${FORCE_UNTIL}" >&2
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
  workspace_dir="$(cd "${SVTESTS_DIR}/.." && pwd)"
  maybe_license="${workspace_dir}/LR-277765_License.dat"
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

if [[ ! -d "${SVTESTS_DIR}/tests/generated" && "${AUTO_GENERATE}" != "0" && "${AUTO_GENERATE}" != "false" && "${AUTO_GENERATE}" != "no" && "${AUTO_GENERATE}" != "off" ]]; then
  echo "[info] tests/generated missing; running template generator"
  make -C "${SVTESTS_DIR}" generate-template_generator -j"$(nproc)"
fi

mkdir -p "${OUT_DIR}/logs/questa_vcd" "${OUT_DIR}/artifacts"

tmp_tests_file="$(mktemp)"
cleanup() { rm -f "${tmp_tests_file}"; }
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
echo "[tests] ${num_tests}"
echo "[out] ${OUT_DIR}"
echo "[force] mode=simulation SVTESTS_UVM_FORCE_RUN_UNTIL=${FORCE_UNTIL}"

export OUT_DIR
export CONF_DIR="${SVTESTS_DIR}/conf"
export TESTS_DIR="${SVTESTS_DIR}/tests"
export RUNNERS_DIR="${SVTESTS_DIR}/tools/runners"
export THIRD_PARTY_DIR="${SVTESTS_DIR}/third_party"
export GENERATORS_DIR="${SVTESTS_DIR}/generators"
export OVERRIDE_TEST_TIMEOUTS="${OVERRIDE_TEST_TIMEOUTS:-1800}"

export QUESTA_ARTIFACTS="vcd"
export QUESTA_ARTIFACT_ROOT="${OUT_DIR}/artifacts/questa_vcd"

export SVTESTS_FORCE_MODE="simulation"
export SVTESTS_UVM_FORCE_RUN_UNTIL="${FORCE_UNTIL}"

runner_param="--quiet"
if [[ "${KEEP_TMP}" != "0" && "${KEEP_TMP}" != "false" && "${KEEP_TMP}" != "no" && "${KEEP_TMP}" != "off" ]]; then
  runner_param="--keep-tmp"
fi

export SVTESTS_DIR runner_param

cat "${tmp_tests_file}" | xargs -P "${WORKERS}" -n 1 bash -lc '
set -euo pipefail
t="$1"
out="${OUT_DIR}/logs/questa_vcd/${t}.log"
mkdir -p "$(dirname "${out}")"
"${SVTESTS_DIR}/tools/runner" --runner Questa_vcd --test "${t}" --out "${out}" "${runner_param}" || true
' _

python3 - "${SVTESTS_DIR}" "${OUT_DIR}" "${tmp_tests_file}" >"${OUT_DIR}/summary.txt" <<'PY'
import os
import re
import sys
from pathlib import Path

svtests_dir = Path(sys.argv[1])
out_dir = Path(sys.argv[2])
tests_file = Path(sys.argv[3])

tests_root = svtests_dir / "tests"
vcd_root = out_dir / "artifacts" / "questa_vcd"
logs_root = out_dir / "logs" / "questa_vcd"

meta_re = re.compile(r"^\\s*:([a-zA-Z_-]+):\\s*(.+)$")

def sanitize_path_component(value: str) -> str:
    value = value.replace(os.sep, "__")
    value = re.sub(r"[^a-zA-Z0-9_.-]+", "_", value)
    value = value.strip("._-") or "unnamed"
    return value

def parse_meta(path: Path) -> dict[str, str]:
    meta: dict[str, str] = {}
    try:
        for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            m = meta_re.match(line)
            if not m:
                continue
            meta[m.group(1).lower()] = m.group(2).strip()
    except OSError:
        pass
    return meta

def compute_artifact_stem(test_rel: str) -> str:
    test_path = tests_root / test_rel
    meta = parse_meta(test_path)
    name = meta.get("name", test_rel)
    files = meta.get("files", test_rel).split()
    abs_files: list[Path] = []
    for f in files:
        p = Path(f)
        abs_files.append(p if p.is_absolute() else (tests_root / p))

    candidates: list[str] = []
    for path in abs_files:
        abs_path = path.resolve()
        try:
            rel = os.path.relpath(str(abs_path), str(tests_root.resolve()))
        except ValueError:
            continue
        if rel != ".." and not rel.startswith(".." + os.sep):
            candidates.append(rel)
    non_support = [rel for rel in candidates if not rel.startswith("support" + os.sep)]
    chosen = non_support[-1] if non_support else (candidates[-1] if candidates else name)
    return sanitize_path_component(chosen)

def parse_rc(log_path: Path) -> int | None:
    try:
        for line in log_path.read_text(encoding="utf-8", errors="ignore").splitlines():
            if line.startswith("rc:"):
                try:
                    return int(line.split(":", 1)[1].strip())
                except ValueError:
                    return None
    except OSError:
        return None
    return None

def scan_vcd(vcd: Path) -> tuple[str, int]:
    cur_t = 0
    last_change_t = 0
    saw_enddefinitions = False
    saw_var = False
    try:
        with vcd.open("r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if not line:
                    continue
                if line.startswith("$var"):
                    saw_var = True
                if "$enddefinitions" in line:
                    saw_enddefinitions = True
                if line.startswith("#"):
                    try:
                        cur_t = int(line[1:].strip() or "0")
                    except ValueError:
                        continue
                    continue
                if line.startswith("$"):
                    continue
                if saw_enddefinitions and line[:1] and line[0] in "01xXzZbBrRsS":
                    last_change_t = cur_t
    except OSError:
        return ("missing", 0)
    if not saw_enddefinitions:
        return ("invalid", 0)
    if not saw_var:
        return ("empty", 0)
    return ("valid", last_change_t)

tests = [l.strip() for l in tests_file.read_text(encoding="utf-8", errors="ignore").splitlines() if l.strip()]

total = len(tests)
expected_fail = 0
rc_ok = 0
rc_fail = 0
vcd_valid = 0
vcd_empty = 0
vcd_invalid = 0
vcd_missing = 0

vcd_ok_tests: list[str] = []
vcd_bad_tests: list[str] = []

for rel in tests:
    meta = parse_meta(tests_root / rel)
    should_fail = meta.get("should_fail", "0").strip() == "1" or "should_fail_because" in meta
    if should_fail:
        expected_fail += 1

    stem = compute_artifact_stem(rel)
    vcd = vcd_root / stem / "wave.vcd"
    status, last = scan_vcd(vcd)

    log = logs_root / f"{rel}.log"
    rc = parse_rc(log)
    if rc == 0:
        rc_ok += 1
    elif rc is not None:
        rc_fail += 1

    if status == "valid":
        vcd_valid += 1
        vcd_ok_tests.append(rel)
    elif status == "empty":
        vcd_empty += 1
        vcd_bad_tests.append(rel)
    elif status == "invalid":
        vcd_invalid += 1
        vcd_bad_tests.append(rel)
    else:
        vcd_missing += 1
        vcd_bad_tests.append(rel)

print(f"total_tests={total}")
print(f"should_fail_meta={expected_fail}")
print(f"runner_rc_ok={rc_ok}")
print(f"runner_rc_fail={rc_fail}")
print(f"vcd_valid={vcd_valid}")
print(f"vcd_empty={vcd_empty}")
print(f"vcd_invalid={vcd_invalid}")
print(f"vcd_missing={vcd_missing}")

(out_dir / "vcd_ok_tests.txt").write_text(
    "\n".join(vcd_ok_tests) + ("\n" if vcd_ok_tests else ""), encoding="utf-8"
)
(out_dir / "vcd_bad_tests.txt").write_text(
    "\n".join(vcd_bad_tests) + ("\n" if vcd_bad_tests else ""), encoding="utf-8"
)
PY

echo "[done] summary=${OUT_DIR}/summary.txt"
echo "[done] ok_list=${OUT_DIR}/vcd_ok_tests.txt"
