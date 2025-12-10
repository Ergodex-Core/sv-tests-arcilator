#!/usr/bin/env bash
# Run a small subset of circt_verilog_arc (default 5 tests) with per-stage artifacts.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_ROOT="${LOG_ROOT:-"$ROOT/out/artifacts/circt_verilog_arc_sample"}"
TMP_ARCHIVE_ROOT="${TMP_ARCHIVE_ROOT:-"$ROOT/out/artifacts/circt_verilog_arc_sample_tmp"}"
TEST_LIST="${TEST_LIST:-"$ROOT/../tempnotes/uvm_arc_status.json"}"
RUNNER="${RUNNER:-circt_verilog_arc}"
TEST_LIMIT=${TEST_LIMIT:-5}
# We run sequentially while scanning the list until we find TEST_LIMIT cases
# that produce a non-empty Arc MLIR artifact.
JOBS=1
TEST_SELECTOR=${TEST_SELECTOR:-pass} # pass|fail|near|all

mkdir -p "$LOG_ROOT" "$TMP_ARCHIVE_ROOT"

if [[ ! -f "$TEST_LIST" ]]; then
  echo "Test list JSON not found: $TEST_LIST" >&2
  exit 1
fi

readarray -t TESTS < <(python3 - "$TEST_LIST" "$TEST_SELECTOR" <<'PY'
import json, sys, pathlib
path = pathlib.Path(sys.argv[1])
selector = sys.argv[2]
data = json.loads(path.read_text())

ordered = []
if selector == "pass":
    ordered = data.get("pass", [])
elif selector == "fail":
    ordered = data.get("fail", [])
elif selector == "near":
    ordered = data.get("near", [])
else:
    ordered = sorted(set(data.get("pass", []) + data.get("fail", []) + data.get("near", [])))

ordered = list(dict.fromkeys(ordered))  # preserve order, de-dupe
for t in ordered:
    if t:
        print(t)
PY
)

OUT_DIR="$ROOT/out"
CONF_DIR="$ROOT/conf"
TESTS_DIR="$ROOT/tests"
RUNNERS_DIR="$ROOT/tools/runners"
THIRD_PARTY_DIR="$ROOT/third_party"
PATH="$ROOT/out/runners/bin:$PATH"
export ROOT LOG_ROOT TMP_ARCHIVE_ROOT RUNNER
export OUT_DIR CONF_DIR TESTS_DIR RUNNERS_DIR THIRD_PARTY_DIR PATH

run_one() {
  local test="$1"
  [[ -z "$test" ]] && return 0
  local stem="${test//\//__}"
  local log="$LOG_ROOT/$stem.log"
  local status="$LOG_ROOT/$stem.status"
  local stage="$LOG_ROOT/$stem.stage"
  mkdir -p "$(dirname "$log")"
  python3 "$ROOT/tools/runner" --runner "$RUNNER" --test "$test" --out "$log" \
    --keep-tmp >> "$log" 2>&1
  local rc=$?
  grep -E "\\[stage\\]" "$log" > "$stage" || true
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
  return 0
}
export -f run_one

found=0
for t in "${TESTS[@]}"; do
  run_one "$t"
  stem="${t//\//__}"
  arc_mlir="$LOG_ROOT/$stem.imported.arc.mlir"
  if [[ -s "$arc_mlir" ]]; then
    ((found++))
    echo "kept $t (arc MLIR present)"
  else
    # Drop empty artifacts to keep the sample directory clean.
    rm -f "$LOG_ROOT/$stem."*
    rm -rf "$TMP_ARCHIVE_ROOT/$stem"
  fi
  if [[ $found -ge $TEST_LIMIT ]]; then
    break
  fi
done

if [[ $found -lt $TEST_LIMIT ]]; then
  echo "Only found $found cases with arc MLIR artifacts (limit $TEST_LIMIT)" >&2
fi

exit 0
