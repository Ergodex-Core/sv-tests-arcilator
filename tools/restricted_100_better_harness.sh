#!/usr/bin/env bash
# Run ~100 SV tests through circt_verilog_arc, then generate and run a per-test
# arcilator C++ harness which drives inputs with "reasonable" waveforms (clk/
# reset/handshake-ish patterns) and emits a VCD. Artifacts are written under an
# output tree that mirrors the test path so you can browse by subfolder.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ROOT="${OUT_ROOT:-"$ROOT/out/artifacts/restricted_100_better"}"
TMP_ROOT="${TMP_ROOT:-"$ROOT/out/tmp_restricted_100_better"}"
ARC_BIN="${ARC_BIN:-"$ROOT/circt-build/bin/arcilator"}"
HEADER_GEN="${HEADER_GEN:-"$ROOT/third_party/tools/circt-verilog/tools/arcilator/arcilator-header-cpp.py"}"
ARC_RUNTIME_INC="${ARC_RUNTIME_INC:-"$ROOT/third_party/tools/circt-verilog/tools/arcilator"}"
CYCLES="${CYCLES:-64}"

# Selection.
CLEAN="${CLEAN:-1}"
SKIP_EXISTING="${SKIP_EXISTING:-1}"
TARGET_COUNT="${TARGET_COUNT:-100}"        # Only applies when loading from TEST_LIST.
ALLOW_ENTRY_ONLY="${ALLOW_ENTRY_ONLY:-0}"  # 0: require module ports; 1: also run entry-only tops.
TEST_LIST="${TEST_LIST:-"$ROOT/../tempnotes/uvm_arc_status.json"}"
TEST_GROUP="${TEST_GROUP:-pass}"           # all|pass|fail|near when TEST_LIST is JSON
TEST_FILTER_RE="${TEST_FILTER_RE:-}"       # Python regex applied to test paths

usage() {
  cat <<EOF
usage: $(basename "$0") [test-path ...]

Runs tests, writes per-test artifacts under OUT_ROOT/<test-path>/.
If you pass explicit test paths, runs exactly those (TARGET_COUNT is ignored).
If you pass none, loads tests from TEST_LIST and runs up to TARGET_COUNT.

Env vars:
  TEST_LIST=path.json|path.txt   Default: $TEST_LIST
  TEST_GROUP=all|pass|fail|near  Default: $TEST_GROUP
  TEST_FILTER_RE=REGEX           Default: (none)
  TARGET_COUNT=N                 Default: $TARGET_COUNT
  ALLOW_ENTRY_ONLY=0|1           Default: $ALLOW_ENTRY_ONLY
  CLEAN=1|0                      Default: $CLEAN
  SKIP_EXISTING=1|0              Default: $SKIP_EXISTING

  OUT_ROOT=... TMP_ROOT=... ARC_BIN=... CYCLES=...

Examples:
  # Run 100 passing Arc tests, browse by chapter directory:
  $(basename "$0")

  # Run only Chapter-16:
  TEST_FILTER_RE='^chapter-16/' $(basename "$0")

  # Run a hand-picked list:
  $(basename "$0") chapter-16/16.2--assert0-uvm.sv chapter-16/16.2--assume-uvm.sv
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
  local json="$1" cpp_out="$2" cycles="$3" header_basename="$4" test_path="$5"
  python3 - "$json" "$cpp_out" "$cycles" "$header_basename" "$test_path" <<'PY'
import json, pathlib, re, sys

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

# Prefer module-name based selection (covers multiple tests sharing the same DUT),
# then allow per-test overrides.
if name == "inverter":
    kind = "inverter_assert"
elif name == "adder":
    kind = "adder_assume"
elif name == "mem_ctrl":
    kind = "mem_ctrl"
elif name == "clk_gen":
    kind = "clk_gen_pipe_valid"

if is_test("chapter-16/16.2--assert0-uvm.sv") or is_test("chapter-16/16.2--assert-final-uvm.sv"):
    kind = "inverter_assert"
elif is_test("chapter-16/16.2--assume-uvm.sv") or is_test("chapter-16/16.2--assert-uvm.sv"):
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
    lines += [
        "  // Drive packed interface input (empirically: [7:0]=data, [15:8]=clk).",
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
    # Generic patterns: toggle clocks, apply a short reset (if present), keep
    # valid/req asserted after reset, and ramp remaining inputs.
    reset_ports = []
    for p in sorted(in_bits):
        pl = p.lower()
        if "reset" in pl or re.fullmatch(r"rst(_n)?|reset(_n)?|rstn|resetn", pl):
            reset_ports.append(p)

    clk_ports = [p for p in sorted(in_bits) if ("clk" in p.lower() or p.lower() == "clock")]

    lines += [
        "  // Default driver: toggles clk-like inputs, applies a short reset,",
        "  // holds valid/req high after reset, ramps others.",
        "  constexpr uint64_t kResetSteps = 4;",
        "  for (uint64_t t = 0; t < kSteps; ++t) {",
    ]

    # Reset(s).
    for p in reset_ports:
        pl = p.lower()
        active_low = pl.endswith("_n") or pl.endswith("rstn") or pl.endswith("resetn")
        if active_low:
            lines += set_bytes(p, "(t < kResetSteps) ? 0u : 1u")
        else:
            lines += set_bytes(p, "(t < kResetSteps) ? 1u : 0u")

    # Clocks: give distinct phases for multiple clocks.
    for idx, p in enumerate(clk_ports):
        lines += set_bytes(p, f"((t + {idx}u) & 1u)")

    # Remaining inputs.
    for idx, p in enumerate(sorted(in_bits)):
        if p in reset_ports or p in clk_ports:
            continue
        pl = p.lower()
        if pl in ("valid", "req"):
            lines += set_bytes(p, "(t < kResetSteps) ? 0u : 1u")
        elif pl in ("en", "enable", "start"):
            lines += set_bytes(p, "(t == kResetSteps) ? 1u : 0u")
        else:
            lines += set_bytes(p, f"((t >> 1) + {idx}u)")

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
  local mlir="$1" dest="$2" test_path="$3"
  local json="$dest/state.json"
  local ll="$dest/imported.ll"
  local hpp="$dest/harness.hpp"
  local cpp="$dest/harness.cpp"
  local bin="$dest/harness.bin"
  local vcd="$dest/harness.vcd"
  local log="$dest/arcilator.log"

  if ! "$ARC_BIN" --state-file "$json" --emit-llvm "$mlir" -o "$ll" \
      --observe-ports --observe-wires --observe-registers --observe-named-values \
      >"$log" 2>&1; then
    echo "  [harness] arcilator failed (see $log)"
    return 1
  fi
  if ! python3 "$HEADER_GEN" "$json" >"$hpp"; then
    echo "  [harness] header generation failed"
    return 1
  fi
  if ! gen_driver "$json" "$cpp" "$CYCLES" "$(basename "$hpp")" "$test_path"; then
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
  return 0
}

if [[ "$CLEAN" != "0" ]]; then
  echo "[clean] removing $OUT_ROOT and $TMP_ROOT"
  rm -rf "$OUT_ROOT" "$TMP_ROOT"
fi
mkdir -p "$OUT_ROOT" "$TMP_ROOT"

summary="$OUT_ROOT/_summary.tsv"
printf "test\tcategory\tharness\tvcd\n" >"$summary"

TESTS=()
enforce_target=1
if [[ $# -gt 0 ]]; then
  TESTS=("$@")
  enforce_target=0
  echo "[info] using ${#TESTS[@]} tests from argv"
else
  [[ -f "$TEST_LIST" ]] || { echo "Test list not found: $TEST_LIST" >&2; exit 1; }
  readarray -t TESTS < <(load_tests "$TEST_LIST" "$TEST_GROUP" "$TEST_FILTER_RE")
  if [[ ${#TESTS[@]} -eq 0 ]]; then
    echo "No tests discovered from TEST_LIST=$TEST_LIST (group=$TEST_GROUP, filter=$TEST_FILTER_RE)" >&2
    exit 1
  fi
  echo "[info] loaded ${#TESTS[@]} tests from $TEST_LIST"
fi

ran=0
for test in "${TESTS[@]}"; do
  if [[ "$enforce_target" == "1" && "$ran" -ge "$TARGET_COUNT" ]]; then
    break
  fi

  src=""
  test_label="$test"
  if [[ -f "$ROOT/tests/$test" ]]; then
    src="$ROOT/tests/$test"
  elif [[ -f "$test" ]]; then
    src="$test"
    test_label="$(python3 - "$src" "$ROOT/tests" <<'PY'
import os, sys
src, tests_root = sys.argv[1:]
src_abs = os.path.abspath(src)
tests_abs = os.path.abspath(tests_root)
try:
    rel = os.path.relpath(src_abs, tests_abs)
    if rel != ".." and not rel.startswith(".."+os.sep):
        print(rel)
    else:
        print(os.path.basename(src_abs))
except Exception:
    print(os.path.basename(src_abs))
PY
    )"
  else
    echo "[skip] missing test file: $test" >&2
    continue
  fi

  dest="$OUT_ROOT/$test_label"
  if [[ "$SKIP_EXISTING" != "0" && -f "$dest/harness.vcd" ]]; then
    printf "%s\t%s\t%s\t%s\n" "$test_label" "existing" "ok" "$dest/harness.vcd" >>"$summary"
    ((ran+=1))
    continue
  fi

  mkdir -p "$dest"
  cp "$src" "$dest/original.sv"

  echo "[run] $test_label"
  runner_log="$dest/runner.log"
  env ROOT="$ROOT" OUT_DIR="$ROOT/out" CONF_DIR="$ROOT/conf" TESTS_DIR="$ROOT/tests" \
    RUNNERS_DIR="$ROOT/tools/runners" THIRD_PARTY_DIR="$ROOT/third_party" \
    PATH="$ROOT/out/runners/bin:$PATH" TMP_ROOT="$TMP_ROOT" LOG_ROOT="$TMP_ROOT/logs" \
    python3 "$ROOT/tools/runner" --runner circt_verilog_arc --test "$src" --out "$runner_log" --keep-tmp >>"$runner_log" 2>&1 || true

  tmp_dir=$(awk '/work directory was left for inspection/{print $NF}' "$runner_log" | tail -n1)
  if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
    cp -f "$tmp_dir"/imported.* "$dest/" 2>/dev/null || true
  fi

  if [[ ! -f "$dest/imported.mlir" ]]; then
    echo "  [warn] missing imported.mlir"
    printf "%s\t%s\t%s\t%s\n" "$test_label" "missing_mlir" "skip" "" >>"$summary"
    continue
  fi

  category=$(categorize "$dest/imported.mlir")
  echo "category=$category" >"$dest/category.txt"

  case "$category" in
    ports_and_entry)
      ;;
    entry_only)
      if [[ "$ALLOW_ENTRY_ONLY" == "0" ]]; then
        echo "  [info] entry-only top; skipping (set ALLOW_ENTRY_ONLY=1 to run)"
        printf "%s\t%s\t%s\t%s\n" "$test_label" "$category" "skip" "" >>"$summary"
        continue
      fi
      ;;
    class_only)
      echo "  [info] class/package only; skipping"
      printf "%s\t%s\t%s\t%s\n" "$test_label" "$category" "skip" "" >>"$summary"
      continue
      ;;
    *)
      echo "  [warn] unknown category=$category; skipping"
      printf "%s\t%s\t%s\t%s\n" "$test_label" "$category" "skip" "" >>"$summary"
      continue
      ;;
  esac

  if run_harness "$dest/imported.mlir" "$dest" "$test_label"; then
    printf "%s\t%s\t%s\t%s\n" "$test_label" "$category" "ok" "$dest/harness.vcd" >>"$summary"
  else
    printf "%s\t%s\t%s\t%s\n" "$test_label" "$category" "fail" "" >>"$summary"
  fi

  ((ran+=1))
done

echo "[done] ran=$ran summary=$summary"
