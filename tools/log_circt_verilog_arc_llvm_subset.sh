#!/usr/bin/env bash
# Run only the known-to-reach-LLVM circt-verilog+Arc tests and persist per-stage logs/status.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_ROOT="${LOG_ROOT:-"$ROOT/out/artifacts/circt_verilog_arc_llvm_subset"}"
TMP_ROOT="${TMP_ROOT:-"$ROOT/out/tmp_arc_stage_llvm_subset"}"
TMP_ARCHIVE_ROOT="${TMP_ARCHIVE_ROOT:-"$ROOT/out/artifacts/circt_verilog_arc_tmp_llvm_subset"}"
RUNNER="${RUNNER:-circt_verilog_arc}"

# Tests confirmed to reach arc emit-llvm successfully.
TESTS=(
  "chapter-16/16.2--assert-final-uvm.sv"
  "chapter-16/16.2--assert0-uvm.sv"
  "chapter-16/16.9--sequence-stable-uvm.sv"
  "generated/uvm_classes_2/uvm_agent_class_2.sv"
  "generated/uvm_classes_2/uvm_component_class_2.sv"
  "generated/uvm_classes_2/uvm_driver_class_2.sv"
  "generated/uvm_classes_2/uvm_env_class_2.sv"
  "generated/uvm_classes_2/uvm_monitor_class_2.sv"
  "generated/uvm_classes_2/uvm_scoreboard_class_2.sv"
  "generated/uvm_classes_2/uvm_sequencer_class_2.sv"
  "generated/uvm_classes_2/uvm_test_class_2.sv"
  "generic/class/class_test_52.sv"
  "generic/member/class_member_test_27.sv"
  "testbenches/uvm_test_run_test.sv"
  "uvm/uvm_files.sv"
)

# Run up to 8 tests in parallel by default.
JOBS=${JOBS:-8}
OUT_DIR="$ROOT/out"
CONF_DIR="$ROOT/conf"
TESTS_DIR="$ROOT/tests"
RUNNERS_DIR="$ROOT/tools/runners"
THIRD_PARTY_DIR="$ROOT/third_party"
PATH="$ROOT/out/runners/bin:$PATH"
export ROOT LOG_ROOT TMP_ROOT TMP_ARCHIVE_ROOT RUNNER
export OUT_DIR CONF_DIR TESTS_DIR RUNNERS_DIR THIRD_PARTY_DIR PATH

mkdir -p "$LOG_ROOT" "$TMP_ROOT" "$TMP_ARCHIVE_ROOT"

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
  # Capture the runner temp dir (if left behind) so the per-stage artifacts
  # (circt-verilog import, Arc MLIR, LLVM IR) are preserved.
  local tmp_dir
  tmp_dir=$(awk '/work directory was left for inspection/{print $NF}' "$log" | tail -n1)
  if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
    local dest="$TMP_ARCHIVE_ROOT/$stem"
    rm -rf "$dest"
    mv "$tmp_dir" "$dest"
    for f in imported.mlir imported.arc.mlir imported.ll; do
      if [[ -f "$dest/$f" ]]; then
        cp "$dest/$f" "$LOG_ROOT/$stem.$f"
      fi
    done
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
