#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# Copyright (C) 2020 The SymbiFlow Authors.
#
# Use of this source code is governed by a ISC-style
# license that can be found in the LICENSE file or at
# https://opensource.org/licenses/ISC
#
# SPDX-License-Identifier: ISC

import os
import shlex

from BaseRunner import BaseRunner


class circt_verilog(BaseRunner):
    def __init__(
        self,
        name="circt-verilog",
        supported_features={"preprocessing", "parsing", "elaboration"},
    ):
        super().__init__(
            name,
            executable="circt-verilog",
            supported_features=supported_features)

        self.submodule = "third_party/tools/circt-verilog"
        self.url = f"https://github.com/llvm/circt/tree/{self.get_commit()}"

    def prepare_run_cb(self, tmp_dir, params):
        circt_cmd = [self.executable]
        mode = params["mode"]

        # To process the input: The preprocessor indicates only run and print preprocessed files;
        # parsing means only lint the input, without elaboration and mapping to CIRCT IR.
        if mode == "preprocessing":
            circt_cmd += ["-E"]
        elif mode == "parsing":
            circt_cmd += ["--parse-only"]

        # The following options are mostly borrowed from the Slang runner, since circt-verilog
        # uses Slang as its Verilog frontend.

        tags = params["tags"]
        incdirs = list(params["incdirs"])
        files = list(params["files"])

        support_dir = os.path.join(os.environ.get("TESTS_DIR", ""), "support")
        if "uvm" in tags and os.path.isdir(support_dir):
            incdirs = [
                support_dir if incdir.endswith("third_party/tests/uvm/src") else incdir
                for incdir in incdirs
            ]
            if support_dir not in incdirs:
                incdirs.insert(0, support_dir)
            stub_pkg = os.path.join(support_dir, "uvm_stub_pkg.sv")
            files = [
                stub_pkg if os.path.basename(path) == "uvm_pkg.sv" else path
                for path in files
            ]

        # Setting for additional include search paths.
        for incdir in incdirs:
            circt_cmd.extend(["-I", incdir])

        # Setting for macro or value defines in all source files.
        for define in params["defines"]:
            circt_cmd.extend(["-D", define])

        # Borrow from slang config for some modules which get errors without a default timescale.
        circt_cmd += ["--timescale=1ns/1ns"]

        # Combine all input files for the tests that need a single compilation unit.
        circt_cmd += ["--single-unit"]

        # Disable certain warnings to make the output less noisy.
        # Some tests access array elements out of bounds. Make that not an error.
        circt_cmd += [
            "-Wno-implicit-conv",
            "-Wno-index-oob",
            "-Wno-range-oob",
            "-Wno-range-width-oob",
        ]

        top = self.get_top_module_or_guess(params)
        if top is not None:
            circt_cmd += ["--top=" + top]

        # The Ariane core does not build correctly if VERILATOR is not defined -- it will attempt
        # to reference nonexistent modules, for example.
        if "ariane" in tags:
            circt_cmd += ["-DVERILATOR"]

        # black-parrot has syntax errors where variables are used before they are declared.
        # This is being fixed upstream, but it might take a long time to make it to master
        # so this works around the problem in the meantime.
        if "black-parrot" in tags and mode != "parsing":
            circt_cmd += ["--allow-use-before-declare"]

            # These tests simply cannot be elaborated because they target
            # modules that have invalid parameter values for a top-level module,
            # or have an invalid configuration that results in $fatal calls.
            name = params["name"]
            if 'bp_lce' in name or 'bp_uce' or 'bp_multicore' in name:
                circt_cmd += ["--parse-only"]

        circt_cmd += files

        # Wrap the invocation in a short script so we can emit stage markers
        # that the log sweep scripts can parse for stuck-phase reporting.
        script_path = os.path.join(tmp_dir, "run_circt_verilog.sh")
        with open(script_path, "w", encoding="utf-8") as script:
            script.write("#!/usr/bin/env bash\n")
            script.write("set -uo pipefail\n")
            script.write('echo "[stage] slang+import (circt-verilog -> moore)"\n')
            script.write(self._format_cmd(circt_cmd) + "\n")
            script.write("circt_rc=$?\n")
            script.write('echo "[stage] circt-verilog rc=${circt_rc}"\n')
            script.write("exit ${circt_rc}\n")
        os.chmod(script_path, 0o755)

        self.cmd = [script_path]

    @staticmethod
    def _format_cmd(cmd):
        return " ".join(shlex.quote(arg) for arg in cmd)
