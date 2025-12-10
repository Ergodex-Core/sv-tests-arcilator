#!/usr/bin/env bash
# Generate simple VCD waveforms for a fixed set of SV tests by:
#  1) re-running arcilator to get state/port metadata and LLVM IR,
#  2) auto-generating a tiny C++ harness that drives all input ports with a
#     monotonically increasing counter, and
#  3) compiling and running that harness to emit a VCD.
#
# This is intentionally narrow in scope: it targets the 15 tests that already
# reach the Arc→LLVM stage. Tests that import zero inputs are skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_ARC_ROOT="${SRC_ARC_ROOT:-"$ROOT/out/artifacts/circt_verilog_arc"}"
OUT_ROOT="${OUT_ROOT:-"$ROOT/out/artifacts/circt_verilog_arc_vcd"}"
ARC_BIN="${ARC_BIN:-"$ROOT/circt-build/bin/arcilator"}"
HEADER_GEN="${HEADER_GEN:-"$ROOT/third_party/tools/circt-verilog/tools/arcilator/arcilator-header-cpp.py"}"
ARC_RUNTIME_INC="${ARC_RUNTIME_INC:-"$ROOT/third_party/tools/circt-verilog/tools/arcilator"}"
CYCLES="${CYCLES:-32}"

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

command -v clang >/dev/null 2>&1 || { echo "clang not found"; exit 1; }
[[ -x "$ARC_BIN" ]] || { echo "arcilator not found at $ARC_BIN"; exit 1; }

mkdir -p "$OUT_ROOT"

gen_driver() {
  local json="$1"
  local cpp_out="$2"
  local cycles="$3"
  local header_basename="$4"
  python3 - "$json" "$cpp_out" "$cycles" "$header_basename" <<'PY'
import json, math, pathlib, sys, textwrap
json_path, cpp_out, cycles, header_basename = sys.argv[1:]
cycles = int(cycles)
data = json.loads(pathlib.Path(json_path).read_text())
if not data:
    sys.exit(4)
model = data[0]
inputs = [s for s in model["states"] if s["type"] == "input"]
if not inputs:
    # Signal to the caller to skip compilation for this test.
    sys.exit(3)

def byte_len(bits: int) -> int:
    return (bits + 7) // 8

lines = [
    "#include <cstdint>",
    "#include <cstring>",
    "#include <fstream>",
    "#include <iostream>",
    f"#include \"{header_basename}\"",
    "",
    "int main(int argc, char** argv) {",
    f"  constexpr uint64_t kCycles = {cycles};",
    f"  {model['name']} dut;",
    "  const char* vcd_path = (argc > 1) ? argv[1] : \"wave.vcd\";",
    "  std::ofstream vcd(vcd_path);",
    "  if (!vcd) { std::cerr << \"failed to open VCD output: \" << vcd_path << \"\\n\"; return 1; }",
    "  auto vcd_writer = dut.vcd(vcd);",
    "  for (uint64_t t = 0; t < kCycles; ++t) {",
]

for idx, port in enumerate(inputs):
    bytes_needed = byte_len(port["numBits"])
    port_name = port["name"]
    lines.append(f"    {{")
    lines.append(f"      uint64_t val = t + {idx};")
    lines.append(f"      std::memcpy(&dut.view.{port_name}, &val, {bytes_needed});")
    lines.append(f"    }}")

lines += [
    "    dut.eval();",
    "    vcd_writer.writeTimestep(10);",
    "  }",
    "  return 0;",
    "}",
]

pathlib.Path(cpp_out).write_text("\n".join(lines) + "\n")
PY
}

for test in "${TESTS[@]}"; do
  stem="${test//\//__}"
  mlir="$SRC_ARC_ROOT/$stem.imported.mlir"
  if [[ ! -f "$mlir" ]]; then
    echo "[skip] $test (missing $mlir)"
    continue
  fi

  json="$OUT_ROOT/$stem.state.json"
  ll="$OUT_ROOT/$stem.ll"
  hpp="$OUT_ROOT/$stem.hpp"
  cpp="$OUT_ROOT/$stem.cpp"
  bin="$OUT_ROOT/$stem.bin"
  vcd="$OUT_ROOT/$stem.vcd"
  log="$OUT_ROOT/$stem.log"

  echo "[build] $test"
  if ! "$ARC_BIN" --observe-ports --state-file "$json" --emit-llvm "$mlir" -o "$ll" >"$log" 2>&1; then
    echo "  arcilator failed; see $log"
    continue
  fi

  if ! python3 "$HEADER_GEN" "$json" > "$hpp"; then
    echo "  header generation failed"
    continue
  fi

  if ! gen_driver "$json" "$cpp" "$CYCLES" "$(basename "$hpp")"; then
    rc=$?
    if [[ $rc -eq 3 ]]; then
      echo "  no input ports; skipping harness"
      continue
    fi
    if [[ $rc -eq 4 ]]; then
      echo "  no model info; skipping harness"
      continue
    fi
    echo "  driver generation failed (rc=$rc)"
    continue
  fi

  if ! ${CXX:-clang++} -std=c++17 -mllvm -opaque-pointers "$ll" "$cpp" -I"$ARC_RUNTIME_INC" -I"$OUT_ROOT" -o "$bin" >>"$log" 2>&1; then
    echo "  clang failed; see $log"
    continue
  fi

  if ! "$bin" "$vcd" >>"$log" 2>&1; then
    echo "  sim run failed; see $log"
    continue
  fi

  echo "  VCD: $vcd"
done
