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


class circt_verilog_arc(BaseRunner):
    """Run circt-verilog on a test and immediately feed the emitted MLIR into
    arcilator so the Arc/LLVM pipeline is exercised (even if it currently
    fails)."""

    def __init__(self):
        super().__init__(
            name="circt-verilog-arc",
            executable="circt-verilog",
            # Accept parsing so parsing-only tests still exercise the pipeline.
            supported_features={"parsing", "elaboration"},
        )
        self.arc_executable = "arcilator"
        self.submodule = "third_party/tools/circt-verilog"
        self.url = f"https://github.com/llvm/circt/tree/{self.get_commit()}"

    def can_run(self):
        """Both circt-verilog and arcilator need to be built."""
        return (shutil.which(self.executable) is not None and
                shutil.which(self.arc_executable) is not None)

    def prepare_run_cb(self, tmp_dir, params):
        ir_path = os.path.join(tmp_dir, "imported.mlir")
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
        circt_cmd += [
            "-Wno-implicit-conv",
            "-Wno-index-oob",
            "-Wno-range-oob",
            "-Wno-range-width-oob",
        ]

        top = self.get_top_module_or_guess(params)
        if top:
            circt_cmd.append(f"--top={top}")

        tags = params["tags"]
        if "ariane" in tags:
            circt_cmd += ["-DVERILATOR"]

        if "black-parrot" in tags and mode != "parsing":
            circt_cmd += ["--allow-use-before-declare"]

        circt_cmd += ["-o", ir_path]
        circt_cmd += files

        arc_cmd = [self.arc_executable, ir_path]

        script_path = os.path.join(tmp_dir, "run_arc.sh")
        with open(script_path, "w", encoding="utf-8") as script:
            script.write("#!/usr/bin/env bash\n")
            script.write("set -euo pipefail\n")
            script.write(self._format_cmd(circt_cmd) + "\n")
            script.write(self._format_cmd(arc_cmd) + "\n")
        os.chmod(script_path, 0o755)

        self.cmd = [script_path]

    @staticmethod
    def _format_cmd(cmd):
        return " ".join(shlex.quote(arg) for arg in cmd)
