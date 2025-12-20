#!/usr/bin/env bash
# Run Chapter-16 UVM tests by importing `module top` (forced top) and emitting
# per-test artifacts + VCDs under an output tree that mirrors the test path.
#
# This is an "all-in" harness in the sense that it simulates the SystemVerilog
# testbench top (not just the DUT). Note: full UVM class/phasing semantics are
# still limited by what reaches the Arc pipeline.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ROOT="${OUT_ROOT:-"$ROOT/out/artifacts/chapter16_top"}"
TMP_ROOT="${TMP_ROOT:-"$ROOT/out/tmp_chapter16_top"}"
ARC_BIN="${ARC_BIN:-"$ROOT/circt-build/bin/arcilator"}"
HEADER_GEN="${HEADER_GEN:-"$ROOT/third_party/tools/circt-verilog/tools/arcilator/arcilator-header-cpp.py"}"
ARC_RUNTIME_INC="${ARC_RUNTIME_INC:-"$ROOT/third_party/tools/circt-verilog/tools/arcilator"}"

# Simulation controls.
CYCLES="${CYCLES:-128}"
DT="${DT:-10}"

# Selection.
CLEAN="${CLEAN:-1}"
SKIP_EXISTING="${SKIP_EXISTING:-1}"
TARGET_COUNT="${TARGET_COUNT:-0}" # 0 = all discovered tests
TEST_LIST="${TEST_LIST:-"$ROOT/../tempnotes/uvm_arc_status.json"}"
TEST_GROUP="${TEST_GROUP:-all}" # all|pass|fail|near when TEST_LIST is JSON
TEST_FILTER_RE="${TEST_FILTER_RE:-^chapter-16/}"
RUNNER="${RUNNER:-circt_verilog_arc_top}"
MODEL_NAME="${MODEL_NAME:-top}"

usage() {
  cat <<EOF
usage: $(basename "$0") [test-path ...]

If no test paths are provided, loads tests from TEST_LIST filtered by
TEST_FILTER_RE (default: Chapter-16).

Env vars:
  TEST_LIST=path.json|path.txt   Default: $TEST_LIST
  TEST_GROUP=all|pass|fail|near  Default: $TEST_GROUP
  TEST_FILTER_RE=REGEX           Default: $TEST_FILTER_RE
  TARGET_COUNT=N                 Default: $TARGET_COUNT (0=all)
  RUNNER=name                    Default: $RUNNER
  MODEL_NAME=name                Default: $MODEL_NAME (preferred state.json model)

  CYCLES=N DT=N                  Default: CYCLES=$CYCLES DT=$DT
  OUT_ROOT=... TMP_ROOT=...      Defaults: $OUT_ROOT, $TMP_ROOT
  CLEAN=1|0 SKIP_EXISTING=1|0

Examples:
  # Run all Chapter-16 tests (from tempnotes status JSON):
  $(basename "$0")

  # Run a single test:
  $(basename "$0") chapter-16/16.2--assert-uvm.sv
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

command -v clang >/dev/null 2>&1 || { echo "clang not found"; exit 1; }
[[ -x "$ARC_BIN" ]] || { echo "arcilator not found at $ARC_BIN"; exit 1; }

load_tests() {
  local list="$1" group="$2" filter_re="$3"
  python3 - "$list" "$group" "$filter_re" <<'PY'
import json, pathlib, re, sys

path = pathlib.Path(sys.argv[1])
group = sys.argv[2]
filter_re = sys.argv[3]

def emit(tests):
    if filter_re:
        rx = re.compile(filter_re)
        tests = [t for t in tests if rx.search(t)]
    for t in sorted(set(tests)):
        if t:
            print(t)

if path.suffix == ".json":
    data = json.loads(path.read_text())
    if group == "all":
        tests = list(data.get("pass", [])) + list(data.get("fail", [])) + list(data.get("near", []))
    else:
        tests = list(data.get(group, []))
    emit(tests)
else:
    lines = [l.strip() for l in path.read_text().splitlines() if l.strip() and not l.strip().startswith("#")]
    emit(lines)
PY
}

TESTS=()
if [[ $# -gt 0 ]]; then
  TESTS=("$@")
else
  [[ -f "$TEST_LIST" ]] || { echo "Test list not found: $TEST_LIST" >&2; exit 1; }
  readarray -t TESTS < <(load_tests "$TEST_LIST" "$TEST_GROUP" "$TEST_FILTER_RE")
  if [[ ${#TESTS[@]} -eq 0 ]]; then
    echo "No tests discovered from TEST_LIST=$TEST_LIST (group=$TEST_GROUP, filter=$TEST_FILTER_RE)" >&2
    exit 1
  fi
  if [[ "$TARGET_COUNT" != "0" ]]; then
    TESTS=("${TESTS[@]:0:$TARGET_COUNT}")
  fi
fi

if [[ "$CLEAN" != "0" ]]; then
  echo "[clean] removing $OUT_ROOT and $TMP_ROOT"
  rm -rf "$OUT_ROOT" "$TMP_ROOT"
fi
mkdir -p "$OUT_ROOT" "$TMP_ROOT"

SUMMARY="$OUT_ROOT/_summary.tsv"
echo -e "test\tstatus\tvcd" > "$SUMMARY"

gen_driver() {
  local json="$1" cpp_out="$2" cycles="$3" dt="$4" header_basename="$5" model_name="$6"
  python3 - "$json" "$cpp_out" "$cycles" "$dt" "$header_basename" "$model_name" <<'PY'
import json, pathlib, re, sys

json_path, cpp_out, cycles, dt, header_basename, model_name = sys.argv[1:]
cycles = int(cycles)
dt = int(dt)
models = json.loads(pathlib.Path(json_path).read_text())
if not models:
    sys.exit(4)

model = None
if model_name:
    for m in models:
        if m.get("name") == model_name:
            model = m
            break
if model is None:
    for m in models:
        if m.get("name") == "top":
            model = m
            break
if model is None:
    model = models[0]

name = model["name"]
states = model.get("states", [])
inputs = [s for s in states if s.get("type") == "input"]
in_bits = {s["name"]: int(s["numBits"]) for s in inputs}

def byte_len(bits: int) -> int:
    return (bits + 7) // 8

def set_bytes(port: str, val_expr: str) -> list[str]:
    bits = in_bits.get(port)
    if bits is None:
        return [f"    // [skip] no input named '{port}' in state.json"]
    nbytes = byte_len(bits)
    if nbytes <= 8:
        return [
            "    {",
            f"      uint64_t tmp = static_cast<uint64_t>({val_expr});",
            f"      std::memcpy(&dut.view.{port}, &tmp, {nbytes});",
            "    }",
        ]
    return [
        "    {",
        f"      std::array<uint8_t, {nbytes}> tmp{{}};",
        f"      uint64_t seed = static_cast<uint64_t>({val_expr});",
        f"      for (size_t i = 0; i < tmp.size(); ++i)",
        "        tmp[i] = static_cast<uint8_t>((seed >> (8 * (i & 7u))) & 0xFFu);",
        f"      std::memcpy(&dut.view.{port}, tmp.data(), tmp.size());",
        "    }",
    ]

clk_candidates = [n for n in in_bits.keys() if re.search(r"(^|/)clk$", n) or re.search(r"clock", n)]
clk_port = clk_candidates[0] if clk_candidates else ""

lines: list[str] = [
    "#include <array>",
    "#include <cstdint>",
    "#include <cstring>",
    "#include <fstream>",
    "#include <iostream>",
    f"#include \"{header_basename}\"",
    "",
    "template <typename TDut, typename TVcd>",
    "static inline void write_step(TDut &dut, TVcd &vcd_writer, uint64_t dt) {",
    "  dut.eval();",
    "  vcd_writer.writeTimestep(dt);",
    "}",
    "",
    "int main(int argc, char** argv) {",
    f"  constexpr uint64_t kSteps = {cycles};",
    f"  constexpr uint64_t kDt = {dt};",
    f"  {name} dut;",
    "  const char* vcd_path = (argc > 1) ? argv[1] : \"wave.vcd\";",
    "  std::ofstream vcd(vcd_path);",
    "  if (!vcd) { std::cerr << \"failed to open VCD output: \" << vcd_path << \"\\n\"; return 1; }",
    "  auto vcd_writer = dut.vcd(vcd);",
    "",
    "  // Step 0: let initial blocks settle.",
    "  write_step(dut, vcd_writer, 1);",
    "",
    "  for (uint64_t t = 0; t < kSteps; ++t) {",
]

if clk_port:
    lines += [
        f"    // Drive {clk_port} as a simple toggle.",
        *set_bytes(clk_port, "(t & 1u)"),
    ]

lines += [
    "    write_step(dut, vcd_writer, kDt);",
    "  }",
    "  return 0;",
    "}",
]

pathlib.Path(cpp_out).write_text("\n".join(lines) + "\n")
PY
}

run_harness() {
  local mlir="$1" dest="$2"
  local json="$dest/state.json"
  local ll="$dest/imported.ll"
  local hpp="$dest/model.hpp"
  local cpp="$dest/driver.cpp"
  local bin="$dest/driver.bin"
  local vcd="$dest/wave.vcd"
  local log="$dest/arcilator.log"

  if ! "$ARC_BIN" --observe-ports --observe-wires --observe-registers --observe-named-values \
      --state-file "$json" --emit-llvm "$mlir" -o "$ll" >"$log" 2>&1; then
    echo "  [harness] arcilator failed (see $log)"
    return 1
  fi

  if ! python3 "$HEADER_GEN" "$json" > "$hpp"; then
    echo "  [harness] header generation failed"
    return 1
  fi

  if ! gen_driver "$json" "$cpp" "$CYCLES" "$DT" "$(basename "$hpp")" "$MODEL_NAME"; then
    echo "  [harness] driver generation failed"
    return 1
  fi

  if ! ${CXX:-clang++} -std=c++17 -mllvm -opaque-pointers "$ll" "$cpp" \
      -I"$ARC_RUNTIME_INC" -I"$dest" -o "$bin" >>"$log" 2>&1; then
    echo "  [harness] clang failed (see $log)"
    return 1
  fi

  if ! "$bin" "$vcd" >>"$log" 2>&1; then
    echo "  [harness] sim run failed (see $log)"
    return 1
  fi
  echo "  [harness] VCD: $vcd"
}

for test in "${TESTS[@]}"; do
  dest="$OUT_ROOT/$test"
  mkdir -p "$dest"

  if [[ "$SKIP_EXISTING" != "0" && -f "$dest/wave.vcd" ]]; then
    echo "[skip] $test (wave.vcd exists)"
    continue
  fi

  src="$ROOT/tests/$test"
  if [[ ! -f "$src" ]]; then
    echo "[warn] missing test file: $src"
    echo -e "${test}\tmissing\t" >> "$SUMMARY"
    continue
  fi
  cp "$src" "$dest/original.sv"

  echo "[run] $test"
  runner_log="$dest/runner.log"
  env ROOT="$ROOT" OUT_DIR="$ROOT/out" CONF_DIR="$ROOT/conf" TESTS_DIR="$ROOT/tests" \
    RUNNERS_DIR="$ROOT/tools/runners" THIRD_PARTY_DIR="$ROOT/third_party" \
    PATH="$ROOT/out/runners/bin:$PATH" TMP_ROOT="$TMP_ROOT" LOG_ROOT="$TMP_ROOT/logs" \
    python3 "$ROOT/tools/runner" --runner "$RUNNER" --test "$test" --out "$runner_log" --keep-tmp \
      >>"$runner_log" 2>&1 || true

  tmp_dir=$(awk '/work directory was left for inspection/{print $NF}' "$runner_log" | tail -n1)
  if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
    cp -f "$tmp_dir"/imported.* "$dest/" 2>/dev/null || true
  fi

  if [[ ! -f "$dest/imported.mlir" ]]; then
    echo "  [warn] missing imported.mlir"
    echo -e "${test}\timport_fail\t" >> "$SUMMARY"
    continue
  fi

  if run_harness "$dest/imported.mlir" "$dest"; then
    echo -e "${test}\tok\t$dest/wave.vcd" >> "$SUMMARY"
  else
    echo -e "${test}\tharness_fail\t" >> "$SUMMARY"
  fi
done

echo "[done] summary: $SUMMARY"
