#!/usr/bin/env bash
# Run circt_verilog across the UVM suite and persist logs/status per test.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_ROOT="${LOG_ROOT:-"$ROOT/out/artifacts/circt_verilog"}"
TMP_ROOT="${TMP_ROOT:-"$ROOT/out/tmp_circt_verilog"}"
# Snapshots of the runner temp dirs (captures any MLIR/LL/aux files the
# runner leaves behind when invoked with --keep-tmp).
TMP_ARCHIVE_ROOT="${TMP_ARCHIVE_ROOT:-"$ROOT/out/artifacts/circt_verilog_tmp"}"
TEST_LIST="${TEST_LIST:-"$ROOT/../tempnotes/uvm_test_status.json"}"
RUNNER="${RUNNER:-circt_verilog}"

mkdir -p "$LOG_ROOT" "$TMP_ROOT" "$TMP_ARCHIVE_ROOT"

if [[ ! -f "$TEST_LIST" ]]; then
  echo "Test list JSON not found: $TEST_LIST" >&2
  exit 1
fi

readarray -t TESTS < <(python3 - "$TEST_LIST" <<'PY'
import json, sys, pathlib
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
tests = sorted(set(data.get("pass", []) + data.get("fail", []) + data.get("near", [])))
for t in tests:
    if t:
        print(t)
PY
)

env_common=(
  OUT_DIR="$ROOT/out"
  CONF_DIR="$ROOT/conf"
  TESTS_DIR="$ROOT/tests"
  RUNNERS_DIR="$ROOT/tools/runners"
  THIRD_PARTY_DIR="$ROOT/third_party"
  PATH="$ROOT/out/runners/bin:$PATH"
)

# Run up to 40 tests at once by default.
JOBS=${JOBS:-40}
OUT_DIR="$ROOT/out"
CONF_DIR="$ROOT/conf"
TESTS_DIR="$ROOT/tests"
RUNNERS_DIR="$ROOT/tools/runners"
THIRD_PARTY_DIR="$ROOT/third_party"
PATH="$ROOT/out/runners/bin:$PATH"
export ROOT LOG_ROOT TMP_ROOT TMP_ARCHIVE_ROOT RUNNER
export OUT_DIR CONF_DIR TESTS_DIR RUNNERS_DIR THIRD_PARTY_DIR PATH
run_one() {
  local test="$1"
  [[ -z "$test" ]] && return 0
  local stem="${test//\//__}"
  local log="$LOG_ROOT/$stem.log"
  local status="$LOG_ROOT/$stem.status"
  local stage="$LOG_ROOT/$stem.stage"
  mkdir -p "$(dirname "$log")"
  set +e
  python3 "$ROOT/tools/runner" --runner "$RUNNER" --test "$test" --out "$log" \
    --keep-tmp >> "$log" 2>&1
  local rc=$?
  set -e
  grep -E "\\[stage\\]" "$log" > "$stage" || true
  # Grab the temp directory (if the runner left one) so we keep any
  # intermediate artifacts.
  local tmp_dir
  tmp_dir=$(awk '/work directory was left for inspection/{print $NF}' "$log" | tail -n1)
  if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
    local dest="$TMP_ARCHIVE_ROOT/$stem"
    rm -rf "$dest"
    mv "$tmp_dir" "$dest"
  fi
  local stage_rc
  stage_rc=$(sed -n 's/.*rc=\([0-9-]\+\).*/\1/p' "$stage" | tail -n1)
  if [[ -n "$stage_rc" ]]; then
    rc="$stage_rc"
  fi
  printf "rc=%s\n" "$rc" > "$status"
}
export -f run_one
printf "%s\n" "${TESTS[@]}" | xargs -n1 -P "${JOBS}" bash -c 'run_one "$1"' _
