#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# Copyright (C) 2026 The SV Tests Authors.
#
# SPDX-License-Identifier: ISC

import os
import re
import shlex
import shutil

from BaseRunner import BaseRunner


def _sanitize_path_component(value: str) -> str:
    value = value.replace(os.sep, "__")
    value = re.sub(r"[^a-zA-Z0-9_.-]+", "_", value)
    return value.strip("._-") or "unnamed"


class Questa_vcd(BaseRunner):
    """Questa runner that emits a per-test VCD under OUT_DIR/artifacts/.

    Intended for VCD parity benchmarking against other simulators.
    """

    def __init__(self):
        super().__init__(
            "questa_vcd",
            "vsim",
            {
                "preprocessing",
                "parsing",
                "elaboration",
                "simulation",
                "simulation_without_run",
            },
        )

        # Filled in by prepare_run_cb for artifact capture.
        self._tmp_vcd_path = ""
        self._artifact_dir = ""

    def _module_defined(self, files, module_name: str) -> bool:
        module_re = re.compile(
            rf"(?m)^\s*module\s+{re.escape(module_name)}\b")
        for path in files:
            try:
                with open(path, "r", encoding="utf-8", errors="ignore") as f:
                    if module_re.search(f.read()):
                        return True
            except OSError:
                continue
        return False

    def _pick_top_module(self, params) -> str:
        explicit = params.get("top_module") or ""
        if explicit:
            return explicit

        if self._module_defined(params.get("files", []), "top"):
            return "top"

        return self.guess_top_module(params) or "top"

    def prepare_run_cb(self, tmp_dir, params):
        mode = params["mode"]
        scr = os.path.join(tmp_dir, "scr.sh")
        dofile = os.path.join(tmp_dir, "run.do")

        # Use a shell wrapper so we can run multiple commands.
        self.cmd = ["bash", "scr.sh"]

        # Compile as a multi-file compilation unit so compilation-unit `bind`
        # statements (e.g. svtests_uvm_m0) get elaborated by Questa.
        vlog_cmd = ["vlog", "-sv", "-mfcu", "-cuname", "svtests_cu"]
        # Define UVM_NO_DPI by default; sv-tests does not require DPI, and it
        # avoids needing tool-specific DPI builds.
        vlog_cmd.append("+define+UVM_NO_DPI")

        for incdir in params.get("incdirs", []):
            vlog_cmd.append("+incdir+" + incdir)

        for define in params.get("defines", []):
            vlog_cmd.append("+define+" + define)

        # Allow per-test flags.
        if "runner_questa_vcd_flags" in params:
            vlog_cmd += shlex.split(params["runner_questa_vcd_flags"])

        vlog_cmd += params.get("files", [])

        vsim_cmd = []
        if mode == "simulation":
            top = self._pick_top_module(params)
            self._tmp_vcd_path = os.path.join(tmp_dir, "wave.vcd")

            with open(dofile, "w", encoding="utf-8") as f:
                f.write("vcd file wave.vcd\n")
                # Dump only the design hierarchy rooted at the chosen top.
                # Dumping `/*` also includes packages (e.g. `uvm_pkg`) and can
                # lead to extremely large headers or truncated VCD output.
                # Prefer ports-only dumps to avoid capturing dynamic scopes
                # created by task/function frames during UVM execution (which
                # can yield truncated headers for some tests).
                f.write(f"vcd add -r -ports /{top}/*\n")
                f.write("run -all\n")
                # Ensure buffered VCD content is written before exit.
                f.write("vcd flush\n")
                f.write("quit -f\n")

            vsim_cmd = [
                "vsim",
                "-c",
                "-voptargs=+acc",
                top,
                "-do",
                "run.do",
            ]

        self._artifact_dir = self._compute_artifact_dir(params)

        with open(scr, "w", encoding="utf-8") as f:
            f.write("set -euo pipefail\n")
            f.write("set -x\n")
            f.write("vlib work\n")
            f.write(f"{' '.join(shlex.quote(a) for a in vlog_cmd)} |& tee compile.log\n")
            if mode == "simulation":
                f.write(f"{' '.join(shlex.quote(a) for a in vsim_cmd)} |& tee run.log\n")

    def run_subprocess(self, tmp_dir, params):
        log, rc = super().run_subprocess(tmp_dir, params)
        self._maybe_save_artifacts(tmp_dir, params, rc)
        return log, rc

    def _compute_artifact_dir(self, params) -> str:
        artifacts_mode = os.environ.get("QUESTA_ARTIFACTS", "0").strip().lower()
        save_artifacts = artifacts_mode not in ("", "0", "false", "no", "off")
        if not save_artifacts:
            return ""

        out_dir = os.environ.get("OUT_DIR", "")
        if not out_dir:
            return ""

        artifacts_root = os.environ.get("QUESTA_ARTIFACT_ROOT", "").strip()
        if not artifacts_root:
            artifacts_root = os.path.join(out_dir, "artifacts", "questa_vcd")
        artifacts_root = os.path.abspath(artifacts_root)

        tests_root = os.environ.get("TESTS_DIR", "").strip()
        test_rel = params.get("name", "unknown_test")
        if tests_root:
            tests_root = os.path.abspath(tests_root)
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
                rel for rel in candidates if not rel.startswith("support" + os.sep)
            ]
            if non_support:
                test_rel = non_support[-1]
            elif candidates:
                test_rel = candidates[-1]

        stem = _sanitize_path_component(test_rel)
        return os.path.join(artifacts_root, stem)

    def _maybe_save_artifacts(self, tmp_dir, params, rc: int) -> None:
        artifacts_mode = os.environ.get("QUESTA_ARTIFACTS", "0").strip().lower()
        save_artifacts = artifacts_mode not in ("", "0", "false", "no", "off")
        if not save_artifacts or not self._artifact_dir:
            return

        onfail_only = artifacts_mode in ("onfail", "fail", "failure")
        if onfail_only and rc == 0:
            return
        vcd_only = artifacts_mode in ("vcd", "vcdonly", "wave", "waveonly")

        os.makedirs(self._artifact_dir, exist_ok=True)

        if not vcd_only:
            compile_log = os.path.join(tmp_dir, "compile.log")
            if os.path.exists(compile_log):
                shutil.copy2(compile_log, os.path.join(self._artifact_dir, "compile.log"))

            run_log = os.path.join(tmp_dir, "run.log")
            if os.path.exists(run_log):
                shutil.copy2(run_log, os.path.join(self._artifact_dir, "run.log"))

        if self._tmp_vcd_path and os.path.exists(self._tmp_vcd_path):
            shutil.copy2(self._tmp_vcd_path, os.path.join(self._artifact_dir, "wave.vcd"))
