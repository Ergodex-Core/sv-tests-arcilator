#!/usr/bin/env bash
# Drive a single SV test through circt_verilog_arc and produce a VCD (when
# possible). If the top module lacks ports, we synthesize a simple ext_clk
# input/output to make a harness driv-able. Usage:
#   single_sv_to_vcd.sh path/to/test.sv [artifact_subdir_name]
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 path/to/test.sv [artifact_subdir_name]" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_PATH="$(python3 - "$1" "$ROOT" <<'PY'
import os, sys
path, root = sys.argv[1:]
print(os.path.abspath(os.path.join(root, path)))
PY
)"

if [[ ! -f "$SRC_PATH" ]]; then
  echo "source file not found: $SRC_PATH" >&2
  exit 1
fi

STEM_DEFAULT="$(python3 - "$SRC_PATH" "$ROOT" <<'PY'
import os, sys
path, root = sys.argv[1:]
rel = os.path.relpath(path, root)
print(rel.replace('/', '__'))
PY
)"
STEM="${2:-$STEM_DEFAULT}"

OUT_ROOT="${OUT_ROOT:-"$ROOT/out/artifacts/single_sv_vcd"}"
DEST="$OUT_ROOT/$STEM"
TMP_ROOT="${TMP_ROOT:-"$ROOT/out/tmp_single_sv_vcd"}"
ARC_BIN="${ARC_BIN:-"$ROOT/circt-build/bin/arcilator"}"
HEADER_GEN="${HEADER_GEN:-"$ROOT/third_party/tools/circt-verilog/tools/arcilator/arcilator-header-cpp.py"}"
ARC_RUNTIME_INC="${ARC_RUNTIME_INC:-"$ROOT/third_party/tools/circt-verilog/tools/arcilator"}"
CYCLES="${CYCLES:-32}"

command -v clang >/dev/null 2>&1 || { echo "clang not found"; exit 1; }
[[ -x "$ARC_BIN" ]] || { echo "arcilator not found at $ARC_BIN"; exit 1; }

mkdir -p "$OUT_ROOT" "$TMP_ROOT"
rm -rf "$DEST"
mkdir -p "$DEST"
cp "$SRC_PATH" "$DEST/original.sv"

gen_driver() {
  local json="$1" cpp_out="$2" cycles="$3" header_basename="$4"
  python3 - "$json" "$cpp_out" "$cycles" "$header_basename" <<'PY'
import json, pathlib, sys
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
    bytes_needed = (port["numBits"] + 7) // 8
    name = port["name"]
    lines.append("    {")
    lines.append(f"      uint64_t val = t + {idx};")
    lines.append(f"      std::memcpy(&dut.view.{name}, &val, {bytes_needed});")
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
out, patched = [], False
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
for i, l in enumerate(out):
    if re.match(r'\s*moore\.output\b', l):
        if l.strip() == "moore.output":
            out[i] = re.sub(r'moore\.output\s*$', "moore.output %ext_clk : !moore.l1", l)
        break
pathlib.Path(dst).write_text("\n".join(out) + "\n")
PY
}

categorize() {
  local mlir="$1"
  python3 - "$mlir" <<'PY'
import pathlib, re, sys
t = pathlib.Path(sys.argv[1]).read_text()
m = re.search(r'moore\.module\s+@([^(]+)\(([^)]*)\)', t)
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
      echo "  [harness] no inputs; skipping VCD"
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

runner_log="$DEST/runner.log"
env ROOT="$ROOT" OUT_DIR="$ROOT/out" CONF_DIR="$ROOT/conf" TESTS_DIR="$ROOT/tests" \
  RUNNERS_DIR="$ROOT/tools/runners" THIRD_PARTY_DIR="$ROOT/third_party" \
  PATH="$ROOT/out/runners/bin:$PATH" TMP_ROOT="$TMP_ROOT" LOG_ROOT="$TMP_ROOT/logs" \
  python3 "$ROOT/tools/runner" --runner circt_verilog_arc --test "$SRC_PATH" --out "$runner_log" --keep-tmp >>"$runner_log" 2>&1 || true

tmp_dir=$(awk '/work directory was left for inspection/{print $NF}' "$runner_log" | tail -n1)
if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
  cp -f "$tmp_dir"/imported.* "$DEST/" 2>/dev/null || true
fi

if [[ ! -f "$DEST/imported.mlir" ]]; then
  echo "[warn] missing imported.mlir"
  exit 0
fi

cat <<EOF > "$DEST/category.txt"
$(date -Iseconds)
EOF

category=$(categorize "$DEST/imported.mlir")
echo "[info] category=$category" | tee -a "$DEST/category.txt"

case "$category" in
  ports_and_entry)
    run_harness "$DEST/imported.mlir" "$STEM" "$DEST"
    ;;
  entry_only)
    patched="$DEST/patched.mlir"
    if patch_noport_mlir "$DEST/imported.mlir" "$patched"; then
      echo "[info] synthesized ext_clk port" | tee -a "$DEST/category.txt"
      run_harness "$patched" "$STEM" "$DEST"
    else
      echo "[warn] failed to synthesize ports" | tee -a "$DEST/category.txt"
    fi
    ;;
  class_only)
    echo "[info] class/package only; harness skipped" | tee -a "$DEST/category.txt"
    ;;
esac
