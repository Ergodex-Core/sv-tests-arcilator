#!/usr/bin/env bash
# Run the arcilator harness across the entire UVM suite (all tests listed in
# tempnotes/uvm_test_status.json by default), capturing per-test MLIR/LLVM
# artifacts and VCDs where possible. This is the full-version counterpart to
# tools/restricted_30_run.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_ROOT="${OUT_ROOT:-"$ROOT/out/artifacts/uvm_full"}"
TMP_ROOT="${TMP_ROOT:-"$ROOT/out/tmp_uvm_full"}"
ARC_BIN="${ARC_BIN:-"$ROOT/circt-build/bin/arcilator"}"
HEADER_GEN="${HEADER_GEN:-"$ROOT/third_party/tools/circt-verilog/tools/arcilator/arcilator-header-cpp.py"}"
ARC_RUNTIME_INC="${ARC_RUNTIME_INC:-"$ROOT/third_party/tools/circt-verilog/tools/arcilator"}"
CYCLES="${CYCLES:-32}"
TEST_LIST="${TEST_LIST:-"$ROOT/../tempnotes/uvm_test_status.json"}"
RUNNER="${RUNNER:-circt_verilog_arc}"

command -v clang >/dev/null 2>&1 || { echo "clang not found"; exit 1; }
[[ -x "$ARC_BIN" ]] || { echo "arcilator not found at $ARC_BIN"; exit 1; }
[[ -f "$TEST_LIST" ]] || { echo "Test list JSON not found: $TEST_LIST"; exit 1; }

readarray -t TESTS < <(python3 - "$TEST_LIST" <<'PY'
import json, sys, pathlib
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
tests = sorted(set(data.get("pass", []) + data.get("fail", []) + data.get("near", [])))
for t in tests:
    if t:
        print(t)
PY
)

if [[ ${#TESTS[@]} -eq 0 ]]; then
  echo "No tests discovered from $TEST_LIST"
  exit 1
fi

echo "[info] loaded ${#TESTS[@]} tests from $TEST_LIST"
echo "[clean] removing $OUT_ROOT and $TMP_ROOT"
rm -rf "$OUT_ROOT" "$TMP_ROOT"
mkdir -p "$OUT_ROOT" "$TMP_ROOT"

gen_driver() {
  local json="$1"
  local cpp_out="$2"
  local cycles="$3"
  local header_basename="$4"
  python3 - "$json" "$cpp_out" "$cycles" "$header_basename" <<'PY'
import json, math, pathlib, sys
json_path, cpp_out, cycles, header_basename = sys.argv[1:]
cycles = int(cycles)
data = json.loads(pathlib.Path(json_path).read_text())
if not data:
    sys.exit(4)
model = data[0]
inputs = [s for s in model["states"] if s["type"] == "input"]
if not inputs:
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
    lines.append("    {")
    lines.append(f"      uint64_t val = t + {idx};")
    lines.append(f"      std::memcpy(&dut.view.{port_name}, &val, {bytes_needed});")
    lines.append("    }")
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

patch_noport_mlir() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" <<'PY'
import re, sys, pathlib
src, dst = sys.argv[1:]
lines = pathlib.Path(src).read_text().splitlines()
out = []
patched = False
for line in lines:
    m = re.match(r'(\s*)moore\.module\s+@([^(]+)\(\)\s*{', line)
    if m and not patched:
        indent, name = m.group(1), m.group(2)
        out.append(f"{indent}moore.module @{name}(in %ext_clk : !moore.l1, out ext_clk_out : !moore.l1) {{")
        patched = True
    else:
        out.append(line)
if not patched:
    sys.exit(2)
for i, line in enumerate(out):
    if re.match(r'\s*moore\.output\b', line):
        if line.strip() == "moore.output":
            out[i] = re.sub(r'moore\.output\s*$', "moore.output %ext_clk : !moore.l1", line)
        break
pathlib.Path(dst).write_text("\n".join(out) + "\n")
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

run_harness() {
  local mlir="$1" stem="$2" dest="$3"
  local json="$dest/state.json"
  local ll="$dest/imported.ll"
  local hpp="$dest/${stem}.hpp"
  local cpp="$dest/${stem}.cpp"
  local bin="$dest/${stem}.bin"
  local vcd="$dest/${stem}.vcd"
  local log="$dest/arcilator.log"

  if ! "$ARC_BIN" --observe-ports --state-file "$json" --emit-llvm "$mlir" -o "$ll" >"$log" 2>&1; then
    echo "  [harness] arcilator failed (see $log)"
    return
  fi
  if ! python3 "$HEADER_GEN" "$json" > "$hpp"; then
    echo "  [harness] header generation failed"
    return
  fi
  if ! gen_driver "$json" "$cpp" "$CYCLES" "$(basename "$hpp")"; then
    rc=$?
    if [[ $rc -eq 3 ]]; then
      echo "  [harness] no inputs after synthesis; skipping VCD"
      return
    fi
    echo "  [harness] driver generation failed (rc=$rc)"
    return
  fi
  if ! ${CXX:-clang++} -std=c++17 -mllvm -opaque-pointers "$ll" "$cpp" -I"$ARC_RUNTIME_INC" -I"$dest" -o "$bin" >>"$log" 2>&1; then
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
    python3 "$ROOT/tools/runner" --runner "$RUNNER" --test "$test" --out "$runner_log" --keep-tmp >>"$runner_log" 2>&1 || true

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
    ports_and_entry)
      run_harness "$dest/imported.mlir" "$stem" "$dest"
      ;;
    entry_only)
      patched="$dest/patched.mlir"
      if patch_noport_mlir "$dest/imported.mlir" "$patched"; then
        echo "  [info] synthesized ext_clk port"
        run_harness "$patched" "$stem" "$dest"
      else
        echo "  [warn] failed to synthesize ports"
      fi
      ;;
    class_only)
      echo "  [info] class/package only; harness skipped"
      ;;
  esac
done
