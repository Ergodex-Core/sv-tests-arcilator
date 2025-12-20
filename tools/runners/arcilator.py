#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# Copyright (C) 2025 The SV Tests Authors.
#
# SPDX-License-Identifier: ISC

import os
import re
import shlex
import shutil

from BaseRunner import BaseRunner


def _is_executable(path: str) -> bool:
    return bool(path) and os.path.isfile(path) and os.access(path, os.X_OK)


def _abspath_or_empty(path: str) -> str:
    if not path:
        return ""
    return os.path.abspath(path)


def _is_truthy_env(name: str, default: str = "0") -> bool:
    val = os.environ.get(name, default)
    return str(val).strip().lower() not in ("", "0", "false", "no", "off")


def _sanitize_path_component(text: str) -> str:
    # Keep artifact dir names stable and filesystem-safe.
    text = text.replace(os.sep, "__")
    text = re.sub(r"[^a-zA-Z0-9_.-]+", "_", text)
    return text.strip("._-") or "unnamed"


class arcilator(BaseRunner):
    """Run a full Arcilator simulation for sv-tests.

    Flow (arc-tests style):
      1) circt-verilog imports SystemVerilog into Moore IR (MLIR)
      2) arcilator lowers Moore IR to LLVM IR and emits a state JSON descriptor
      3) arcilator-header-cpp.py generates a C++ model header from state JSON
      4) a small C++ driver is generated to:
           - instantiate the model
           - optionally drive input ports (simple heuristics)
           - call eval() for N timesteps
      5) clang++ compiles and runs the driver
    """

    def __init__(self):
        super().__init__(
            name="arcilator",
            executable="arcilator",
            supported_features={
                "preprocessing",
                "parsing",
                "elaboration",
                "simulation",
                "simulation_without_run",
            },
        )
        self.submodule = "third_party/tools/circt-verilog"
        self.url = f"https://github.com/llvm/circt/tree/{self.get_commit()}"

        svtests_root = os.path.abspath(
            os.path.join(os.path.dirname(__file__), os.pardir, os.pardir)
        )
        default_bin_dir = os.path.join(svtests_root, "circt-build", "bin")
        self._bin_dir = os.environ.get("CIRCT_BIN_DIR", default_bin_dir)

        self._circt_verilog = _abspath_or_empty(
            os.environ.get(
                "CIRCT_VERILOG_BIN",
                shutil.which("circt-verilog")
                or os.path.join(self._bin_dir, "circt-verilog"),
            )
        )
        self._arcilator = _abspath_or_empty(
            os.environ.get(
                "ARCILATOR_BIN",
                shutil.which("arcilator") or os.path.join(self._bin_dir, "arcilator"),
            )
        )

        third_party_arcilator_dir = os.path.join(
            svtests_root, "third_party", "tools", "circt-verilog", "tools", "arcilator"
        )
        default_header_gen = os.path.join(self._bin_dir, "arcilator-header-cpp.py")
        if not os.path.isfile(default_header_gen):
            default_header_gen = os.path.join(third_party_arcilator_dir,
                                             "arcilator-header-cpp.py")
        self._header_gen = _abspath_or_empty(
            os.environ.get("ARCILATOR_HEADER_GEN", default_header_gen)
        )

        # Directory that contains arcilator-runtime.h (included by generated headers).
        default_runtime_inc = self._bin_dir
        if not os.path.isfile(os.path.join(default_runtime_inc, "arcilator-runtime.h")):
            default_runtime_inc = third_party_arcilator_dir
        self._runtime_inc = _abspath_or_empty(
            os.environ.get("ARCILATOR_RUNTIME_INC", default_runtime_inc)
        )
        # Ensure BaseRunner utilities (version, etc.) use the resolved binary.
        if self._arcilator:
            self.executable = self._arcilator

    def can_run(self):
        return (
            _is_executable(self._circt_verilog)
            and _is_executable(self._arcilator)
            and os.path.isfile(self._header_gen)
            and os.path.isdir(self._runtime_inc)
            and shutil.which(os.environ.get("CXX", "clang++")) is not None
        )

    @staticmethod
    def _format_cmd(cmd):
        return " ".join(shlex.quote(arg) for arg in cmd)

    @staticmethod
    def _module_defined(files, module_name: str) -> bool:
        # Best-effort scan; false negatives are ok (we fall back to other guesses).
        # Match `module <name> ...` with common delimiters.
        regex = re.compile(rf"\bmodule\s+{re.escape(module_name)}\s*[#(;]")
        for path in files:
            try:
                with open(path, "r", encoding="utf-8", errors="ignore") as f:
                    if regex.search(f.read()):
                        return True
            except OSError:
                continue
        return False

    def _pick_top_module(self, params):
        explicit = params.get("top_module") or ""
        if explicit:
            return explicit
        env_top = os.environ.get("ARCILATOR_TOP") or os.environ.get(
            "CIRCT_VERILOG_TOP"
        )
        if env_top:
            return env_top
        tags = params.get("tags", "")
        if "uvm" in tags:
            # Default to the historical behavior (run the first module/DUT) to
            # avoid selecting class-heavy `module top` testbenches.
            #
            # To get a pessimistic (more realistic) read on UVM suites, set:
            #   ARCILATOR_UVM_TOP_MODE=top
            # which prefers `module top` when it exists.
            uvm_top = (os.environ.get("ARCILATOR_UVM_TOP") or "").strip()
            if uvm_top:
                return uvm_top
            uvm_mode = (os.environ.get("ARCILATOR_UVM_TOP_MODE") or "dut").strip().lower()
            if uvm_mode in ("top", "tb", "testbench"):
                if self._module_defined(params.get("files", []), "top"):
                    return "top"
            return self.guess_top_module(params)
        if self._module_defined(params.get("files", []), "top"):
            return "top"
        return self.guess_top_module(params)

    def prepare_run_cb(self, tmp_dir, params):
        mode = params["mode"]
        ir_path = os.path.join(tmp_dir, "imported.mlir")
        arc_mlir_path = os.path.join(tmp_dir, "imported.arc.mlir")
        state_path = os.path.join(tmp_dir, "state.json")
        llvm_path = os.path.join(tmp_dir, "imported.ll")
        header_path = os.path.join(tmp_dir, "model.hpp")
        driver_cpp = os.path.join(tmp_dir, "driver.cpp")
        driver_bin = os.path.join(tmp_dir, "driver.bin")

        circt_cmd = [self._circt_verilog]
        if mode == "preprocessing":
            circt_cmd += ["-E"]
        elif mode == "parsing":
            circt_cmd += ["--parse-only"]

        for incdir in params["incdirs"]:
            circt_cmd.extend(["-I", incdir])

        for define in params["defines"]:
            if define:
                circt_cmd.extend(["-D", define])

        # No tests require UVM DPI, and some frontends do not support it well.
        tags = params.get("tags", "")
        if "uvm" in tags:
            circt_cmd.append("-DUVM_NO_DPI")

        circt_cmd += ["--timescale=1ns/1ns", "--single-unit"]

        # Request Moore IR so arcilator can consume the elaborated design.
        if mode in ("elaboration", "simulation", "simulation_without_run"):
            circt_cmd.append("--ir-moore")

        circt_cmd += [
            "-Wno-implicit-conv",
            "-Wno-index-oob",
            "-Wno-range-oob",
            "-Wno-range-width-oob",
        ]

        top = self._pick_top_module(params)
        if top:
            circt_cmd.append(f"--top={top}")

        if "ariane" in tags:
            circt_cmd += ["-DVERILATOR"]
        if "black-parrot" in tags and mode != "parsing":
            circt_cmd += ["--allow-use-before-declare"]

        if mode in ("elaboration", "simulation", "simulation_without_run"):
            circt_cmd += ["-o", ir_path]

        circt_cmd += list(params["files"])

        arc_flags = []
        if "runner_arcilator_flags" in params:
            arc_flags += shlex.split(params["runner_arcilator_flags"])

        # arcilator does the conversion and can optionally emit intermediate MLIR.
        arc_mlir_cmd = self._format_cmd(
            [self._arcilator, "--emit-mlir", ir_path] + arc_flags
        ) + f" > {shlex.quote(arc_mlir_path)}"

        # For simulation we also need a state file and LLVM output.
        arc_emit_argv = [
            self._arcilator,
            "--observe-ports",
            "--observe-wires",
            "--observe-registers",
            "--observe-named-values",
            "--state-file",
            state_path,
            "--emit-llvm",
            ir_path,
            "-o",
            llvm_path,
        ] + arc_flags
        arc_emit_cmd = self._format_cmd(arc_emit_argv)

        # Driver controls (compile-time constants for simplicity).
        cycles = os.environ.get("ARCILATOR_CYCLES", os.environ.get("CYCLES", "128"))
        reset_cycles = os.environ.get("ARCILATOR_RESET_CYCLES", "2")
        seed = os.environ.get("ARCILATOR_SEED", "1")
        vcd_dt = os.environ.get("ARCILATOR_VCD_DT", "10")

        # Optional artifact capture (MLIR, LLVM IR, driver, VCD).
        artifacts_mode = os.environ.get("ARCILATOR_ARTIFACTS", "0").strip().lower()
        save_artifacts = artifacts_mode not in ("", "0", "false", "no", "off")
        onfail_only = artifacts_mode in ("onfail", "fail", "failure")
        artifacts_root = os.environ.get("ARCILATOR_ARTIFACT_ROOT", "")
        if not artifacts_root:
            out_dir = os.environ.get("OUT_DIR", "")
            if out_dir:
                artifacts_root = os.path.join(out_dir, "artifacts", "arcilator")
        artifacts_root = _abspath_or_empty(artifacts_root)

        tests_root = _abspath_or_empty(os.environ.get("TESTS_DIR", ""))
        test_rel = ""
        if tests_root:
            candidates = []
            for path in params.get("files", []):
                abs_path = os.path.abspath(path)
                try:
                    rel = os.path.relpath(abs_path, tests_root)
                except ValueError:
                    continue
                if rel != ".." and not rel.startswith(".." + os.sep):
                    candidates.append(rel)
            non_support = [
                rel for rel in candidates
                if not rel.startswith("support" + os.sep)
            ]
            if non_support:
                test_rel = non_support[-1]
            elif candidates:
                test_rel = candidates[-1]
        if not test_rel:
            test_rel = params.get("name", "unknown_test")
        artifact_stem = _sanitize_path_component(test_rel)
        artifact_dir = (
            os.path.join(artifacts_root, artifact_stem)
            if save_artifacts and artifacts_root
            else ""
        )
        vcd_path = os.path.join(tmp_dir, "wave.vcd")

        script_path = os.path.join(tmp_dir, "run_arcilator_flow.sh")
        with open(script_path, "w", encoding="utf-8") as script:
            script.write("#!/usr/bin/env bash\n")
            script.write("set -uo pipefail\n")
            if save_artifacts and artifact_dir:
                script.write(f'ARTIFACT_MODE={shlex.quote("onfail" if onfail_only else "always")}\n')
                script.write(f'ARTIFACT_DIR={shlex.quote(artifact_dir)}\n')
                script.write('echo "[artifact] dir=${ARTIFACT_DIR}"\n')
                script.write('echo "[artifact] vcd=${ARTIFACT_DIR}/wave.vcd"\n')
                script.write('mkdir -p "${ARTIFACT_DIR}"\n')
                script.write("save_artifacts() {\n")
                script.write("  rc=$?\n")
                script.write("  if [[ \"${ARTIFACT_MODE}\" == \"onfail\" && ${rc} -eq 0 ]]; then return; fi\n")
                for path in (
                    ir_path,
                    arc_mlir_path,
                    state_path,
                    llvm_path,
                    header_path,
                    driver_cpp,
                    driver_bin,
                    vcd_path,
                ):
                    script.write(
                        f'  if [[ -f {shlex.quote(path)} ]]; then cp -f {shlex.quote(path)} "${{ARTIFACT_DIR}}/"; fi\n'
                    )
                script.write("}\n")
                script.write("trap save_artifacts EXIT\n")

            script.write('echo "[stage] slang+import (circt-verilog -> moore)"\n')
            script.write(self._format_cmd(circt_cmd) + "\n")
            script.write("circt_rc=$?\n")
            script.write('echo "[stage] circt-verilog rc=${circt_rc}"\n')
            script.write("if [[ ${circt_rc} -ne 0 ]]; then exit ${circt_rc}; fi\n")

            if mode in ("preprocessing", "parsing"):
                script.write("exit 0\n")
            else:
                script.write(f'echo "[stage] arc pipeline (emit-mlir)"\n')
                script.write(arc_mlir_cmd + "\n")
                script.write("arc_mlir_rc=$?\n")
                script.write('echo "[stage] arcilator emit-mlir rc=${arc_mlir_rc}"\n')
                script.write("if [[ ${arc_mlir_rc} -ne 0 ]]; then exit ${arc_mlir_rc}; fi\n")

                script.write('echo "[stage] arc lower-to-llvm (and write state.json)"\n')
                script.write(arc_emit_cmd + "\n")
                script.write("arc_emit_rc=$?\n")
                script.write('echo "[stage] arcilator emit-llvm rc=${arc_emit_rc}"\n')
                script.write("if [[ ${arc_emit_rc} -ne 0 ]]; then exit ${arc_emit_rc}; fi\n")

                if mode == "elaboration":
                    script.write("exit 0\n")
                else:
                    # Generate model header.
                    script.write(
                        'echo "[stage] header-gen (state.json -> model.hpp)"\n'
                    )
                    script.write(
                        f'python3 {shlex.quote(self._header_gen)} {shlex.quote(state_path)} > {shlex.quote(header_path)}\n'
                    )
                    script.write("hdr_rc=$?\n")
                    script.write('echo "[stage] header-gen rc=${hdr_rc}"\n')
                    script.write(
                        "if [[ ${hdr_rc} -ne 0 ]]; then exit ${hdr_rc}; fi\n"
                    )

                    # Generate the C++ driver from state.json, preferring the selected top model.
                    script.write('echo "[stage] gen-driver (state.json -> driver.cpp)"\n')
                    script.write(
                        f'python3 - {shlex.quote(state_path)} {shlex.quote(driver_cpp)} {shlex.quote(top or "")} {shlex.quote(cycles)} {shlex.quote(reset_cycles)} {shlex.quote(seed)} {shlex.quote(vcd_dt)} {shlex.quote(test_rel)} <<\'PY\'\n'
                    )
                    script.write(r"""import json
import pathlib
import re
import sys

state_json, cpp_out, top_name, cycles_s, reset_cycles_s, seed_s, vcd_dt_s, test_path = sys.argv[1:]
cycles = int(cycles_s)
reset_cycles = int(reset_cycles_s)
seed = int(seed_s)
vcd_dt = int(vcd_dt_s)
test_path = test_path or ""

models = json.loads(pathlib.Path(state_json).read_text())
if not models:
  sys.stderr.write("empty state.json\n")
  sys.exit(2)

model = None
if top_name:
  for m in models:
    if m.get("name") == top_name:
      model = m
      break
if model is None:
  model = models[0]

model_name = model.get("name", "top")
states = model.get("states", [])
inputs = [s for s in states if s.get("type") == "input"]
in_bits = {s.get("name"): int(s.get("numBits", 0)) for s in inputs if s.get("name")}

def byte_len(bits: int) -> int:
  return (bits + 7) // 8

def cpp_port_name(name: str) -> str:
  # Keep in sync with arcilator-header-cpp.py's io renaming.
  if name == "state":
    return "state_"
  return name

def set_bytes(port: str, val_expr: str) -> list[str]:
  bits = in_bits.get(port, 0)
  nbytes = byte_len(bits)
  if nbytes == 0:
    return [f"    // [skip] {port} has 0 bits"]
  port_cpp = cpp_port_name(port)
  if nbytes <= 8:
    return [
      "    {",
      f"      uint64_t tmp = static_cast<uint64_t>({val_expr});",
      f"      std::memcpy(&dut.view.{port_cpp}, &tmp, {nbytes});",
      "    }",
    ]
  return [
    "    {",
    f"      std::array<uint8_t, {nbytes}> tmp{{}};",
    f"      uint64_t x = static_cast<uint64_t>({val_expr});",
    f"      for (size_t i = 0; i < tmp.size(); ++i) {{",
    "        uint64_t rot = (x >> (8 * (i & 7u)));",
    "        tmp[i] = static_cast<uint8_t>(rot & 0xFFu);",
    "      }",
    f"      std::memcpy(&dut.view.{port_cpp}, tmp.data(), tmp.size());",
    "    }",
  ]

def is_clk(name: str) -> bool:
  n = name.lower()
  return bool(re.search(r"(^|_)clk($|_)", n) or n.startswith("clk") or "clock" in n)

def is_rst(name: str) -> bool:
  n = name.lower()
  return "reset" in n or bool(re.search(r"(^|_)rst($|_)", n))

def rst_is_active_low(name: str) -> bool:
  n = name.lower()
  if n.endswith("_n"):
    return True
  if n in ("rst_n", "reset_n", "rstn", "resetn", "nrst", "nreset"):
    return True
  return False

def should_hold_high(name: str) -> bool:
  n = name.lower()
  return n in ("valid", "req", "enable", "en", "wen", "ren")

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

drive_lines: list[str] = []
if kind == "inverter_assert":
  drive_lines += [
    "    // inverter_assert: drive a=8'h35 (matches UVM body).",
  ] + set_bytes("a", "0x35u")
elif kind == "adder_assume":
  drive_lines += [
    "    // adder_assume: drive a=8'h35, b=8'h79, toggle clk.",
  ] + set_bytes("a", "0x35u") + set_bytes("b", "0x79u") + set_bytes("clk", "(t & 1u)")
elif kind == "mem_ctrl":
  drive_lines += [
    "    // mem_ctrl: toggle clk and drive din with a simple pattern.",
  ] + set_bytes("clk", "(t & 1u)") + set_bytes("din", "((t >> 1) & 0xFFu)")
elif kind == "mod_throughout":
  drive_lines += [
    "    // mod_throughout: hold req high; toggle clk.",
  ] + set_bytes("req", "1u") + set_bytes("clk", "(t & 1u)")
elif kind == "stable":
  drive_lines += [
    "    // stable: just toggle clk.",
  ] + set_bytes("clk", "(t & 1u)")
elif kind == "clk_gen_pipe_valid":
  drive_lines += [
    "    // clk_gen_pipe_valid: hold valid high; toggle clk; ramp in.",
  ] + set_bytes("valid", "1u") + set_bytes("clk", "(t & 1u)") + set_bytes("in", "((t >> 1) & 0xFFu)")
elif kind == "multiclock":
  drive_lines += [
    "    // multiclock: drive clk0 and clk1 at different rates.",
  ] + set_bytes("clk0", "(t & 1u)") + set_bytes("clk1", "((t / 3) & 1u)")
elif kind == "iff_rst_stuck_high":
  drive_lines += [
    "    // iff_rst_stuck_high: keep rst asserted; toggle clk.",
  ] + set_bytes("rst", "1u") + set_bytes("clk", "(t & 1u)")
elif kind == "dut_interface_echo" and "in" in in_bits and in_bits.get("in", 0) <= 64:
  # UVM dut has interface modport args. In the lowered model, they show up as a
  # packed integer input. Empirically this is 16b: [7:0]=data, [15:8]=clk (LSB).
  drive_lines += [
    "    // dut_interface_echo: drive input_if.data=2 and input_if.clk=(t&1)",
    "    const uint8_t clk = static_cast<uint8_t>(t & 1u);",
    "    const uint8_t kPattern = 2;",
  ]
  in_nbytes = byte_len(in_bits.get("in", 0))
  drive_lines += [
    "    {",
    "      uint64_t in_packed = static_cast<uint64_t>(kPattern) | (static_cast<uint64_t>(clk) << 8);",
    f"      std::memcpy(&dut.view.{cpp_port_name('in')}, &in_packed, {in_nbytes});",
    "    }",
  ]

  if "out" in in_bits and in_bits.get("out", 0) <= 64:
    out_nbytes = byte_len(in_bits.get("out", 0))
    drive_lines += [
      "    // Keep output_if.clk in sync without clobbering output_if.data.",
      "    {",
      "      uint64_t out_cur = 0;",
      f"      std::memcpy(&out_cur, &dut.view.{cpp_port_name('out')}, {out_nbytes});",
      "      uint64_t out_packed = out_cur;",
      "      out_packed = (out_packed & 0xFFu) | (static_cast<uint64_t>(clk) << 8);",
      f"      std::memcpy(&dut.view.{cpp_port_name('out')}, &out_packed, {out_nbytes});",
      "    }",
    ]
else:
  clk_ports = [p for p in in_bits.keys() if is_clk(p)]
  rst_ports = [p for p in in_bits.keys() if is_rst(p)]
  other_ports = [p for p in in_bits.keys() if p not in clk_ports and p not in rst_ports]

  for port in sorted(clk_ports):
    drive_lines += [f"    // clock: {port}"] + set_bytes(port, "(t & 1u)")

  for port in sorted(rst_ports):
    active_low = rst_is_active_low(port)
    if active_low:
      drive_lines += [f"    // reset (active-low): {port}"] + set_bytes(
        port, "(t < kResetSteps) ? 0u : 1u"
      )
    else:
      drive_lines += [f"    // reset (active-high): {port}"] + set_bytes(
        port, "(t < kResetSteps) ? 1u : 0u"
      )

  for idx, port in enumerate(sorted(other_ports)):
    if should_hold_high(port):
      drive_lines += [f"    // held-high: {port}"] + set_bytes(port, "1u")
    else:
      # Deterministic per-port pattern.
      drive_lines += [f"    // data: {port}"] + set_bytes(
        port, f"(kSeed ^ (t * 6364136223846793005ull + {idx}ull))"
      )

lines: list[str] = []
lines += [
  "#include <array>",
  "#include <cstdint>",
  "#include <cstring>",
  "#include <fstream>",
  "#include <iostream>",
  "#include \"model.hpp\"",
  "",
  "template <typename TDut, typename TVcd>",
  "static inline void write_step(TDut &dut, TVcd &vcd_writer, uint64_t dt) {",
  "  dut.eval();",
  "  vcd_writer.writeTimestep(dt);",
  "}",
  "",
  "int main(int argc, char** argv) {",
  f"  constexpr uint64_t kSteps = {cycles};",
  f"  constexpr uint64_t kResetSteps = {reset_cycles};",
  f"  constexpr uint64_t kSeed = {seed}ull;",
  f"  constexpr uint64_t kVcdDt = {vcd_dt}ull;",
  f"  {model_name} dut;",
  "  const char* vcd_path = (argc > 1) ? argv[1] : \"wave.vcd\";",
  "  std::ofstream vcd(vcd_path);",
  "  if (!vcd) { std::cerr << \"failed to open VCD output: \" << vcd_path << \"\\n\"; return 1; }",
  "  auto vcd_writer = dut.vcd(vcd);",
  "",
  "  // Drive initial input values (t=0).",
  "  {",
  "    const uint64_t t = 0;",
]
lines += drive_lines
lines += [
  "  }",
  "",
  "  // Step 0: let initial blocks settle.",
  "  write_step(dut, vcd_writer, 1);",
  "",
  "  for (uint64_t t = 0; t < kSteps; ++t) {",
]
lines += drive_lines

lines += [
  "    write_step(dut, vcd_writer, kVcdDt);",
  "  }",
  "  return 0;",
  "}",
]

pathlib.Path(cpp_out).write_text("\n".join(lines) + "\n")
""")
                    script.write("PY\n")
                    script.write("drv_rc=$?\n")
                    script.write('echo "[stage] gen-driver rc=${drv_rc}"\n')
                    script.write(
                        "if [[ ${drv_rc} -ne 0 ]]; then exit ${drv_rc}; fi\n"
                    )

                    # Build the simulation driver. Keep flags minimal; users can override CXX.
                    script.write('echo "[stage] clang++ (driver)"\n')
                    cxx = shlex.quote(os.environ.get("CXX", "clang++"))
                    script.write(
                        f'{cxx} -std=c++17 -mllvm -opaque-pointers {shlex.quote(llvm_path)} {shlex.quote(driver_cpp)} '
                        f'-I{shlex.quote(self._runtime_inc)} -I{shlex.quote(tmp_dir)} -o {shlex.quote(driver_bin)}\n'
                    )
                    script.write("cxx_rc=$?\n")
                    script.write('echo "[stage] clang++ rc=${cxx_rc}"\n')
                    script.write(
                        "if [[ ${cxx_rc} -ne 0 ]]; then exit ${cxx_rc}; fi\n"
                    )

                    if mode == "simulation":
                        script.write('echo "[stage] run (driver.bin)"\n')
                        script.write(self._format_cmd([driver_bin, vcd_path]) + "\n")
                        script.write("exit $?\n")
                    else:
                        script.write("exit 0\n")

        os.chmod(script_path, 0o755)
        self.cmd = [script_path]
