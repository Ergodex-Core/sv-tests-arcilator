#!/usr/bin/env bash
# Re-run the same ~30 tests as restricted_30_run.sh, but generate a per-test
# harness that drives inputs in a way that matches the intent of the original
# UVM SV (rather than a generic counter pattern). For tests without ports we
# avoid synthesizing dummy ports and instead rely on `--observe-*` taps.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ROOT="${OUT_ROOT:-"$ROOT/out/artifacts/restricted_30_better"}"
TMP_ROOT="${TMP_ROOT:-"$ROOT/out/tmp_restricted_30_better"}"
ARC_BIN="${ARC_BIN:-"$ROOT/circt-build/bin/arcilator"}"
HEADER_GEN="${HEADER_GEN:-"$ROOT/third_party/tools/circt-verilog/tools/arcilator/arcilator-header-cpp.py"}"
ARC_RUNTIME_INC="${ARC_RUNTIME_INC:-"$ROOT/third_party/tools/circt-verilog/tools/arcilator"}"
CYCLES="${CYCLES:-64}"

TESTS=(
  "chapter-16/16.2--assert-final-uvm.sv"
  "chapter-16/16.2--assert0-uvm.sv"
  "chapter-16/16.2--assume-uvm.sv"
  "chapter-16/16.7--sequence-uvm.sv"
  "chapter-16/16.7--sequence-throughout-uvm.sv"
  "chapter-16/16.9--sequence-stable-uvm.sv"
  "chapter-16/16.10--sequence-local-var-uvm.sv"
  "chapter-16/16.11--sequence-subroutine-uvm.sv"
  "chapter-16/16.13--sequence-multiclock-uvm.sv"
  "chapter-16/16.15--property-iff-uvm.sv"
  "chapter-18/18.5--constraint-blocks_1.sv"
  "chapter-18/18.5.5--uniqueness-constraints_1.sv"
  "chapter-18/18.6.1--randomize-method_0.sv"
  "chapter-18/18.6.3--behavior-of-randomization-methods_1.sv"
  "chapter-18/18.7--in-line-constraints--randomize_0.sv"
  "chapter-18/18.8--disabling-random-variables-with-rand_mode_2.sv"
  "chapter-18/18.9--controlling-constraints-with-constraint_mode_0.sv"
  "chapter-18/18.10--dynamic-constraint-modification_0.sv"
  "chapter-18/18.11--in-line-random-variable-control_0.sv"
  "chapter-18/18.14.3--object-stability_0.sv"
  "generic/class/class_test_52.sv"
  "generic/member/class_member_test_27.sv"
  "testbenches/uvm_test_run_test.sv"
  "testbenches/uvm_driver_sequencer_env.sv"
  "testbenches/uvm_sequence.sv"
  "uvm/uvm_files.sv"
  "generated/uvm_classes_0/uvm_component_class_0.sv"
  "generated/uvm_classes_0/uvm_env_class_0.sv"
  "generated/uvm_classes_0/uvm_test_class_0.sv"
  "generated/uvm_classes_0/uvm_driver_class_0.sv"
)

command -v clang >/dev/null 2>&1 || { echo "clang not found"; exit 1; }
[[ -x "$ARC_BIN" ]] || { echo "arcilator not found at $ARC_BIN"; exit 1; }

echo "[clean] removing $OUT_ROOT and $TMP_ROOT"
rm -rf "$OUT_ROOT" "$TMP_ROOT"
mkdir -p "$OUT_ROOT" "$TMP_ROOT"

categorize() {
  local mlir="$1"
  python3 - "$mlir" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
m = re.search(r'moore\.module\s+@([^(]+)\(([^)]*)\)', text)
if not m:
    print("class_only")
    sys.exit(0)
args = [a.strip() for a in m.group(2).split(",") if a.strip()]
print("ports_and_entry" if args else "entry_only")
PY
}

gen_driver() {
  local json="$1"
  local cpp_out="$2"
  local cycles="$3"
  local header_basename="$4"
  local test_path="$5"
  python3 - "$json" "$cpp_out" "$cycles" "$header_basename" "$test_path" <<'PY'
import json, pathlib, sys

json_path, cpp_out, cycles, header_basename, test_path = sys.argv[1:]
cycles = int(cycles)
models = json.loads(pathlib.Path(json_path).read_text())
if not models:
    sys.exit(4)
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
    return [
        f"    {{",
        f"      uint64_t tmp = static_cast<uint64_t>({val_expr});",
        f"      std::memcpy(&dut.view.{port}, &tmp, {nbytes});",
        f"    }}",
    ]

def get_bytes(port: str) -> tuple[list[str], str]:
    bits = in_bits.get(port)
    if bits is None:
        return ([f"    // [skip] no input named '{port}' in state.json"], "0")
    nbytes = byte_len(bits)
    var = f"{port}_cur"
    lines = [
        f"    uint64_t {var} = 0;",
        f"    std::memcpy(&{var}, &dut.view.{port}, {nbytes});",
    ]
    return (lines, var)

def is_test(suffix: str) -> bool:
    return test_path.endswith(suffix)

kind = "default"
if is_test("chapter-16/16.2--assert0-uvm.sv") or is_test("chapter-16/16.2--assert-final-uvm.sv"):
    kind = "inverter_assert"
elif is_test("chapter-16/16.2--assume-uvm.sv"):
    kind = "adder_assume"
elif is_test("chapter-16/16.7--sequence-uvm.sv"):
    kind = "mem_ctrl"
elif is_test("chapter-16/16.7--sequence-throughout-uvm.sv"):
    kind = "mod_throughout"
elif is_test("chapter-16/16.9--sequence-stable-uvm.sv"):
    kind = "stable"
elif is_test("chapter-16/16.10--sequence-local-var-uvm.sv") or is_test("chapter-16/16.11--sequence-subroutine-uvm.sv"):
    kind = "clk_gen_pipe_valid"
elif is_test("chapter-16/16.13--sequence-multiclock-uvm.sv"):
    kind = "multiclock"
elif is_test("chapter-16/16.15--property-iff-uvm.sv"):
    kind = "iff_rst_stuck_high"
elif is_test("testbenches/uvm_driver_sequencer_env.sv"):
    kind = "dut_interface_echo"

lines: list[str] = [
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
    f"  {name} dut;",
    "  const char* vcd_path = (argc > 1) ? argv[1] : \"wave.vcd\";",
    "  std::ofstream vcd(vcd_path);",
    "  if (!vcd) { std::cerr << \"failed to open VCD output: \" << vcd_path << \"\\n\"; return 1; }",
    "  auto vcd_writer = dut.vcd(vcd);",
    "",
    "  // Step 0: let initial blocks settle.",
    "  write_step(dut, vcd_writer, 1);",
    "",
]

if kind == "inverter_assert":
    # DUT module is inverter(a[7:0]) -> b[7:0] with b = !a (logical-not).
    lines += [
        "  // Drive a to 8'h35 (matches the UVM body).",
        *set_bytes("a", "0x35u"),
        "  for (uint64_t t = 0; t < kSteps; ++t) {",
        "    write_step(dut, vcd_writer, 10);",
        "  }",
    ]
elif kind == "adder_assume":
    lines += [
        "  // Drive clk plus a/b constants (matches the UVM body).",
        *set_bytes("a", "0x35u"),
        *set_bytes("b", "0x79u"),
        "  for (uint64_t t = 0; t < kSteps; ++t) {",
        *set_bytes("clk", "(t & 1u)"),
        "    write_step(dut, vcd_writer, 10);",
        "  }",
    ]
elif kind == "mem_ctrl":
    lines += [
        "  // Drive clk and a simple din pattern; observe read/write/addr/dout.",
        "  for (uint64_t t = 0; t < kSteps; ++t) {",
        *set_bytes("clk", "(t & 1u)"),
        *set_bytes("din", "((t >> 1) & 0xFFu)"),
        "    write_step(dut, vcd_writer, 10);",
        "  }",
    ]
elif kind == "mod_throughout":
    lines += [
        "  // Hold req high (matches the UVM top), toggle clk.",
        *set_bytes("req", "1u"),
        "  for (uint64_t t = 0; t < kSteps; ++t) {",
        *set_bytes("clk", "(t & 1u)"),
        "    write_step(dut, vcd_writer, 10);",
        "  }",
    ]
elif kind == "stable":
    lines += [
        "  // Toggle clk; out is constant 0 by construction in this DUT.",
        "  for (uint64_t t = 0; t < kSteps; ++t) {",
        *set_bytes("clk", "(t & 1u)"),
        "    write_step(dut, vcd_writer, 10);",
        "  }",
    ]
elif kind == "clk_gen_pipe_valid":
    lines += [
        "  // Hold valid high; toggle clk; drive in with a cycle count (matches the UVM top).",
        *set_bytes("valid", "1u"),
        "  for (uint64_t t = 0; t < kSteps; ++t) {",
        *set_bytes("clk", "(t & 1u)"),
        *set_bytes("in", "((t >> 1) & 0xFFu)"),
        "    write_step(dut, vcd_writer, 10);",
        "  }",
    ]
elif kind == "multiclock":
    lines += [
        "  // Two clocks with different rates/phasing (roughly matches the UVM top).",
        "  for (uint64_t t = 0; t < kSteps; ++t) {",
        *set_bytes("clk0", "(t & 1u)"),
        *set_bytes("clk1", "((t / 3) & 1u)"),
        "    write_step(dut, vcd_writer, 10);",
        "  }",
    ]
elif kind == "iff_rst_stuck_high":
    lines += [
        "  // UVM top keeps rst asserted; the property is disabled (out stays 0).",
        *set_bytes("rst", "1u"),
        "  for (uint64_t t = 0; t < kSteps; ++t) {",
        *set_bytes("clk", "(t & 1u)"),
        "    write_step(dut, vcd_writer, 10);",
        "  }",
    ]
elif kind == "dut_interface_echo":
    # The arcilator state packs the interface ports; empirically this is 2 bytes:
    # [7:0]=data, [15:8]=clk (LSB used).
    lines += [
        "  // Drive input_if.clk and input_if.data=PATTERN (2); keep out_if.clk in sync.",
        "  constexpr uint8_t kPattern = 2;",
        "  for (uint64_t t = 0; t < kSteps; ++t) {",
    ]
    if "in" in in_bits and in_bits["in"] <= 64:
        lines += [
            "    uint8_t clk = static_cast<uint8_t>(t & 1u);",
            "    uint16_t in_packed = static_cast<uint16_t>(kPattern) | (static_cast<uint16_t>(clk) << 8);",
            "    std::memcpy(&dut.view.in, &in_packed, sizeof(in_packed));",
        ]
    else:
        lines += ["    // [skip] unexpected interface input packing; falling back to generic input driving."]
        # generic drive all inputs deterministically
        for idx, port in enumerate(sorted(in_bits)):
            lines += set_bytes(port, f"(t + {idx}u)")

    if "out" in in_bits and in_bits["out"] <= 64:
        get_lines, cur = get_bytes("out")
        lines += [
            *get_lines,
            f"    uint16_t out_packed = static_cast<uint16_t>({cur});",
            "    out_packed = static_cast<uint16_t>((out_packed & 0x00FFu) | (static_cast<uint16_t>(t & 1u) << 8));",
            "    std::memcpy(&dut.view.out, &out_packed, sizeof(out_packed));",
        ]
    else:
        lines += ["    // [skip] no 'out' input in state.json (or unexpected width)."]

    lines += [
        "    write_step(dut, vcd_writer, 10);",
        "  }",
    ]
else:
    # Default: toggle any input named *clk*, keep valid/req high if present,
    # and drive remaining inputs with a deterministic ramp.
    lines += [
        "  // Default driver: toggles clk-like inputs, holds valid/req high, ramps others.",
        "  for (uint64_t t = 0; t < kSteps; ++t) {",
    ]
    for port in sorted(in_bits):
        if port.startswith("clk") or "clk" == port:
            lines += set_bytes(port, "(t & 1u)")
        elif port in ("valid", "req"):
            lines += set_bytes(port, "1u")
        else:
            # ramp at a full-cycle rate to avoid anti-phase with clk toggling
            lines += set_bytes(port, "((t >> 1) & 0xFFFFFFFFu)")
    lines += [
        "    write_step(dut, vcd_writer, 10);",
        "  }",
    ]

lines += [
    "  return 0;",
    "}",
]

pathlib.Path(cpp_out).write_text("\n".join(lines) + "\n")
PY
}

run_harness() {
  local mlir="$1" stem="$2" dest="$3" test_path="$4"
  local json="$dest/state.json"
  local ll="$dest/imported.ll"
  local hpp="$dest/${stem}.hpp"
  local cpp="$dest/${stem}.cpp"
  local bin="$dest/${stem}.bin"
  local vcd="$dest/${stem}.vcd"
  local log="$dest/arcilator.log"

  if ! "$ARC_BIN" --state-file "$json" --emit-llvm "$mlir" -o "$ll" \
      --observe-ports --observe-wires --observe-registers --observe-named-values \
      >"$log" 2>&1; then
    echo "  [harness] arcilator failed (see $log)"
    return
  fi
  if ! python3 "$HEADER_GEN" "$json" >"$hpp"; then
    echo "  [harness] header generation failed"
    return
  fi
  if ! gen_driver "$json" "$cpp" "$CYCLES" "$(basename "$hpp")" "$test_path"; then
    echo "  [harness] driver generation failed"
    return
  fi
  if ! ${CXX:-clang++} -std=c++17 -mllvm -opaque-pointers "$ll" "$cpp" \
      -I"$ARC_RUNTIME_INC" -I"$dest" -o "$bin" >>"$log" 2>&1; then
    echo "  [harness] clang failed (see $log)"
    return
  fi
  if ! "$bin" "$vcd" >>"$log" 2>&1; then
    echo "  [harness] sim run failed (see $log)"
    return
  fi
  echo "  [harness] VCD: $vcd"
}

for test in "${TESTS[@]}"; do
  stem="${test//\//__}"
  dest="$OUT_ROOT/$stem"
  mkdir -p "$dest"
  src="$ROOT/tests/$test"
  cp "$src" "$dest/original.sv"

  echo "[run] $test"
  runner_log="$dest/runner.log"
  env ROOT="$ROOT" OUT_DIR="$ROOT/out" CONF_DIR="$ROOT/conf" TESTS_DIR="$ROOT/tests" \
    RUNNERS_DIR="$ROOT/tools/runners" THIRD_PARTY_DIR="$ROOT/third_party" \
    PATH="$ROOT/out/runners/bin:$PATH" TMP_ROOT="$TMP_ROOT" LOG_ROOT="$TMP_ROOT/logs" \
    python3 "$ROOT/tools/runner" --runner circt_verilog_arc --test "$test" --out "$runner_log" --keep-tmp >>"$runner_log" 2>&1 || true

  tmp_dir=$(awk '/work directory was left for inspection/{print $NF}' "$runner_log" | tail -n1)
  if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
    cp -f "$tmp_dir"/imported.* "$dest/" 2>/dev/null || true
  fi

  if [[ ! -f "$dest/imported.mlir" ]]; then
    echo "  [warn] missing imported.mlir"
    continue
  fi

  category=$(categorize "$dest/imported.mlir")
  echo "  [info] category=$category" | tee "$dest/category.txt"

  case "$category" in
    ports_and_entry|entry_only)
      run_harness "$dest/imported.mlir" "$stem" "$dest" "$test"
      ;;
    class_only)
      echo "  [info] class/package only; harness skipped"
      ;;
  esac
done
