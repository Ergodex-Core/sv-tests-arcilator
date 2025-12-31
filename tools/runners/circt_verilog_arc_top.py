#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# Copyright (C) 2025 The SV Tests Authors.
#
# SPDX-License-Identifier: ISC

import os
import shlex
import shutil

from BaseRunner import BaseRunner


def _is_executable(path: str) -> bool:
    return bool(path) and os.path.isfile(path) and os.access(path, os.X_OK)


def _abspath_or_empty(path: str) -> str:
    if not path:
        return ""
    return os.path.abspath(path)


class circt_verilog_arc_top(BaseRunner):
    """Run circt-verilog on a test, forcing `--top=top` (or `CIRCT_VERILOG_TOP`),
    and feed the emitted MLIR into arcilator so the Arc/LLVM pipeline is
    exercised.

    This is useful for UVM-style tests where the file's first module is the DUT
    and the actual testbench is `module top`.
    """

    def __init__(self):
        svtests_root = os.path.abspath(
            os.path.join(os.path.dirname(__file__), os.pardir, os.pardir)
        )
        default_bin_dir = os.path.join(svtests_root, "circt-build", "bin")
        bin_dir = os.environ.get("CIRCT_BIN_DIR", default_bin_dir)

        circt_verilog = (
            os.environ.get("CIRCT_VERILOG_BIN")
            or shutil.which("circt-verilog")
            or os.path.join(bin_dir, "circt-verilog")
        )
        arcilator = (
            os.environ.get("ARCILATOR_BIN")
            or shutil.which("arcilator")
            or os.path.join(bin_dir, "arcilator")
        )

        super().__init__(
            name="circt-verilog-arc-top",
            executable=_abspath_or_empty(circt_verilog),
            supported_features={"parsing", "elaboration"},
        )
        self.arc_executable = _abspath_or_empty(arcilator)
        self.submodule = "third_party/tools/circt-verilog"
        self.url = f"https://github.com/llvm/circt/tree/{self.get_commit()}"

    def can_run(self):
        return _is_executable(self.executable) and _is_executable(self.arc_executable)

    def prepare_run_cb(self, tmp_dir, params):
        ir_path = os.path.join(tmp_dir, "imported.mlir")
        arc_mlir_path = os.path.join(tmp_dir, "imported.arc.mlir")
        llvm_path = os.path.join(tmp_dir, "imported.ll")
        circt_cmd = [self.executable]
        mode = params["mode"]

        if mode == "preprocessing":
            circt_cmd += ["-E"]
        elif mode == "parsing":
            circt_cmd += ["--parse-only"]

        incdirs = list(params["incdirs"])
        files = list(params["files"])

        for incdir in incdirs:
            circt_cmd.extend(["-I", incdir])

        for define in params["defines"]:
            if define:
                circt_cmd.extend(["-D", define])

        circt_cmd += ["--timescale=1ns/1ns", "--single-unit"]
        circt_cmd.append("--ir-moore")
        circt_cmd += [
            "-Wno-implicit-conv",
            "-Wno-index-oob",
            "-Wno-range-oob",
            "-Wno-range-width-oob",
        ]

        top = os.environ.get("CIRCT_VERILOG_TOP", "top")
        if top:
            circt_cmd.append(f"--top={top}")

        tags = params["tags"]
        if "ariane" in tags:
            circt_cmd += ["-DVERILATOR"]

        if "black-parrot" in tags and mode != "parsing":
            circt_cmd += ["--allow-use-before-declare"]

        circt_cmd += ["-o", ir_path]
        circt_cmd += files

        arc_mlir_cmd = (
            f"{self._format_cmd([self.arc_executable, '--emit-mlir', ir_path])}"
            f" > {shlex.quote(arc_mlir_path)}"
        )
        arc_emit_cmd = (
            f"{self._format_cmd([self.arc_executable, '--emit-llvm', ir_path])}"
            f" > {shlex.quote(llvm_path)}"
        )

        script_path = os.path.join(tmp_dir, "run_arc.sh")
        with open(script_path, "w", encoding="utf-8") as script:
            script.write("#!/usr/bin/env bash\n")
            script.write("set -uo pipefail\n")
            script.write('echo "[stage] slang+import (circt-verilog -> moore)"\n')
            script.write(self._format_cmd(circt_cmd) + "\n")
            script.write("circt_rc=$?\n")
            script.write('echo "[stage] circt-verilog rc=${circt_rc}"\n')
            script.write("if [[ ${circt_rc} -ne 0 ]]; then exit ${circt_rc}; fi\n")
            script.write(f'if [[ -f "{ir_path}" ]]; then\n')
            script.write(f'  echo "[artifact] imported.mlir path={ir_path}"\n')
            script.write(f'  head -n 120 "{ir_path}"\n')
            script.write("fi\n")
            script.write('echo "[stage] arc pipeline (convert-to-arcs / emit-mlir)"\n')
            script.write(arc_mlir_cmd + "\n")
            script.write("arc_mlir_rc=$?\n")
            script.write('echo "[stage] arc emit-mlir rc=${arc_mlir_rc}"\n')
            script.write("if [[ ${arc_mlir_rc} -ne 0 ]]; then exit ${arc_mlir_rc}; fi\n")
            script.write(f'if [[ -f "{arc_mlir_path}" ]]; then\n')
            script.write(f'  echo "[artifact] imported.arc.mlir path={arc_mlir_path}"\n')
            script.write(f'  head -n 120 "{arc_mlir_path}"\n')
            script.write("fi\n")
            script.write('echo "[stage] arc lower-to-llvm"\n')
            script.write(arc_emit_cmd + "\n")
            script.write("arc_emit_rc=$?\n")
            script.write('echo "[stage] arc emit-llvm rc=${arc_emit_rc}"\n')
            script.write(f'if [[ -f "{llvm_path}" ]]; then\n')
            script.write(f'  echo "[artifact] imported.ll path={llvm_path}"\n')
            script.write(f'  head -n 80 "{llvm_path}"\n')
            script.write("fi\n")
            script.write("exit ${arc_emit_rc}\n")
        os.chmod(script_path, 0o755)

        self.cmd = [script_path]

    @staticmethod
    def _format_cmd(cmd):
        return " ".join(shlex.quote(arg) for arg in cmd)
