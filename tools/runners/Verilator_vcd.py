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
import re
import shlex
import shutil

from BaseRunner import BaseRunner


def _is_truthy_env(name: str, default: str = "0") -> bool:
    val = os.environ.get(name, default)
    return str(val).strip().lower() not in ("", "0", "false", "no", "off")


def _sanitize_path_component(value: str) -> str:
    # Keep artifact dir names stable and filesystem-safe (match arcilator.py).
    value = value.replace(os.sep, "__")
    value = re.sub(r"[^a-zA-Z0-9_.-]+", "_", value)
    return value.strip("._-") or "unnamed"


class Verilator_vcd(BaseRunner):
    """Verilator runner that emits a per-test VCD under OUT_DIR/artifacts/.

    This is intended for VCD parity benchmarking against arcilator output.
    """

    def __init__(self):
        super().__init__(
            "verilator-vcd",
            "verilator",
            {
                "preprocessing",
                "parsing",
                "elaboration",
                "simulation",
                "simulation_without_run",
            },
        )

        self.c_extensions = [".cc", ".c", ".cpp", ".h", ".hpp"]
        self.allowed_extensions.extend([".vlt"] + self.c_extensions)
        self.submodule = "third_party/tools/verilator"
        self.url = f"https://github.com/verilator/verilator/tree/{self.get_commit()}"

        # Filled in by prepare_run_cb for artifact capture.
        self._tmp_vcd_path = ""
        self._tmp_main_cpp = ""
        self._artifact_dir = ""

    def prepare_run_cb(self, tmp_dir, params):
        mode = params["mode"]
        scr = os.path.join(tmp_dir, "scr.sh")

        # verilator executable is a script but it doesn't have shell shebang on
        # the first line
        self.cmd = ["sh", "scr.sh"]

        # Enable timing control support
        self.cmd.append("--timing")

        if mode in ["simulation", "simulation_without_run"]:
            # We need a custom main to generate a VCD.
            self.cmd += ["--cc", "--exe"]
        elif mode == "preprocessing":
            self.cmd += ["-P", "-E"]
        else:  # parsing and elaboration
            self.cmd += ["--lint-only"]

        # Allow UVM builds within reasonable timeout
        self.cmd += ["--build-jobs", "0"]

        self.cmd += ["-Wno-fatal", "-Wno-UNOPTFLAT", "-Wno-BLKANDNBLK"]
        # Flags for compliance testing
        self.cmd += ["-Wpedantic", "-Wno-context"]

        if params["top_module"] != "":
            self.cmd += ["--top-module", params["top_module"]]
            top = params["top_module"]
        else:
            top = "top"

        # top is None only if the test contains no module; such tests should
        # not be run with simulation-related options.
        build_name = f"V{top}"
        build_dir = "vbuild"
        sim_bin = "sim"

        for incdir in params["incdirs"]:
            self.cmd.append("-I" + incdir)

        # No tests require UVM DPI, and we don't currently have a nice way of
        # knowing when it is needed to put it on the command line. Also avoids
        # compile time of the DPI C code.
        self.cmd.append("-DUVM_NO_DPI")

        if mode in ["simulation", "simulation_without_run"]:
            trace_depth = os.environ.get("VERILATOR_TRACE_DEPTH", "")
            trace_depth = trace_depth.strip() or "99"
            trace_levels = os.environ.get("VERILATOR_TRACE_LEVELS", "")
            trace_levels = trace_levels.strip() or "99"
            timescale = os.environ.get("VERILATOR_TIMESCALE", "1ns/1ns")

            self._tmp_vcd_path = os.path.join(tmp_dir, "wave.vcd")
            self._tmp_main_cpp = os.path.join(tmp_dir, "svtests_vcd_main.cpp")

            with open(self._tmp_main_cpp, "w", encoding="utf-8") as f:
                f.write(
                    f"""#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>

#include \"{build_name}.h\"
#include \"verilated.h\"
#include \"verilated_vcd_c.h\"

static uint64_t getenv_u64(const char* name, uint64_t defaultValue) {{
  const char* val = std::getenv(name);
  if (!val || !*val) return defaultValue;
  char* end = nullptr;
  unsigned long long parsed = std::strtoull(val, &end, 0);
  if (end == val) return defaultValue;
  return static_cast<uint64_t>(parsed);
}}

static int getenv_int(const char* name, int defaultValue) {{
  const char* val = std::getenv(name);
  if (!val || !*val) return defaultValue;
  char* end = nullptr;
  long parsed = std::strtol(val, &end, 0);
  if (end == val) return defaultValue;
  return static_cast<int>(parsed);
}}

int main(int argc, char** argv, char**) {{
  Verilated::debug(0);

  const std::unique_ptr<VerilatedContext> contextp{{new VerilatedContext}};
  contextp->commandArgs(argc, argv);
  contextp->traceEverOn(true);
  contextp->randReset(getenv_int(\"VERILATOR_RAND_RESET\", 0));
  contextp->randSeed(getenv_int(\"VERILATOR_RAND_SEED\", 1));
  contextp->threads(1);

  const std::unique_ptr<{build_name}> topp{{new {build_name}{{contextp.get(), \"\"}}}};

  const char* vcdPath = std::getenv(\"VERILATOR_VCD_PATH\");
  if (!vcdPath || !*vcdPath) vcdPath = \"wave.vcd\";

  const uint64_t traceStart = getenv_u64(\"VERILATOR_TRACE_START\", 0);
  const uint64_t traceEnd = getenv_u64(\"VERILATOR_TRACE_END\", 0);
  const uint64_t maxTime = getenv_u64(\"VERILATOR_MAX_TIME\", 0);
  const uint64_t maxSteps = getenv_u64(\"VERILATOR_MAX_STEPS\", 0);
  const uint64_t deltaLimit = getenv_u64(\"VERILATOR_DELTA_LIMIT\", 1024);

  VerilatedVcdC tfp;
  topp->trace(&tfp, /*levels=*/{trace_levels});
  tfp.open(vcdPath);

  auto dump = [&](uint64_t t) {{
    if (t < traceStart) return;
    if (traceEnd && t > traceEnd) return;
    tfp.dump(t);
  }};

  auto evalSettle = [&]() {{
    topp->eval();
    for (uint64_t delta = 0; delta < deltaLimit; ++delta) {{
      if (!topp->eventsPending()) break;
      const uint64_t next = topp->nextTimeSlot();
      if (next != contextp->time()) break;
      topp->eval();
    }}
  }};

  contextp->time(0);

  uint64_t steps = 0;
  while (VL_LIKELY(!contextp->gotFinish())) {{
    evalSettle();
    dump(contextp->time());

    if (maxSteps && (++steps) >= maxSteps) break;
    if (maxTime && contextp->time() >= maxTime) break;

    if (!topp->eventsPending()) break;
    const uint64_t next = topp->nextTimeSlot();
    if (next <= contextp->time()) {{
      // Avoid infinite loops on pathological schedules; allow progress.
      contextp->timeInc(1);
    }} else {{
      contextp->time(next);
    }}
  }}

  topp->final();
  dump(contextp->time());
  tfp.close();

  contextp->statsPrintSummary();
  return 0;
}}
"""
                )

            self.cmd += [
                self._tmp_main_cpp,
                "--build",
                "--Mdir",
                build_dir,
                "--prefix",
                build_name,
                "--trace",
                "--trace-structs",
                "--trace-depth",
                trace_depth,
                "--timescale-override",
                timescale,
                "-o",
                sim_bin,
            ]

        if "runner_verilator_flags" in params:
            self.cmd += shlex.split(params["runner_verilator_flags"])

        for define in params["defines"]:
            self.cmd.append("-D" + define)

        self.cmd += params["files"]

        self._artifact_dir = self._compute_artifact_dir(params)

        with open(scr, "w", encoding="utf-8") as f:
            f.write("set -eu\n")
            f.write("set -x\n")
            # The Codex sandbox often disallows writes outside the workspace,
            # which breaks ccache's default temp location under /run/user.
            # Redirect ccache into OUT_DIR so it can be shared across tests,
            # while keeping temp files under the per-test tmp dir.
            f.write('if [ -z "${CCACHE_DIR:-}" ]; then\n')
            f.write(
                '  export CCACHE_DIR="${VERILATOR_CCACHE_DIR:-${OUT_DIR:-$PWD}/ccache/verilator_vcd}"\n'
            )
            f.write("fi\n")
            f.write('export CCACHE_TEMPDIR="$PWD/ccache-tmp"\n')
            f.write('mkdir -p "$CCACHE_DIR" "$CCACHE_TEMPDIR"\n')
            f.write(f'{self.executable} "$@" || exit $?\n')
            if mode == "simulation":
                sim_args = shlex.split(os.environ.get("SVTESTS_SIM_ARGS", ""))
                sim_args_str = " ".join(shlex.quote(a) for a in sim_args)
                if sim_args_str:
                    sim_args_str = " " + sim_args_str
                f.write(f"export VERILATOR_VCD_PATH={shlex.quote(self._tmp_vcd_path)}\n")
                f.write(f'./{build_dir}/{sim_bin}{sim_args_str}\n')

    def run_subprocess(self, tmp_dir, params):
        log, rc = super().run_subprocess(tmp_dir, params)
        self._maybe_save_artifacts(tmp_dir, params, rc)
        return log, rc

    def _compute_artifact_dir(self, params) -> str:
        artifacts_mode = os.environ.get("VERILATOR_ARTIFACTS", "0").strip().lower()
        save_artifacts = artifacts_mode not in ("", "0", "false", "no", "off")
        if not save_artifacts:
            return ""

        out_dir = os.environ.get("OUT_DIR", "")
        if not out_dir:
            return ""

        artifacts_root = os.environ.get("VERILATOR_ARTIFACT_ROOT", "").strip()
        if not artifacts_root:
            artifacts_root = os.path.join(out_dir, "artifacts", "verilator_vcd")
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
        artifacts_mode = os.environ.get("VERILATOR_ARTIFACTS", "0").strip().lower()
        save_artifacts = artifacts_mode not in ("", "0", "false", "no", "off")
        if not save_artifacts or not self._artifact_dir:
            return
        onfail_only = artifacts_mode in ("onfail", "fail", "failure")
        if onfail_only and rc == 0:
            return

        os.makedirs(self._artifact_dir, exist_ok=True)

        if self._tmp_main_cpp and os.path.exists(self._tmp_main_cpp):
            shutil.copy2(self._tmp_main_cpp, os.path.join(self._artifact_dir, "svtests_vcd_main.cpp"))

        if self._tmp_vcd_path and os.path.exists(self._tmp_vcd_path):
            shutil.copy2(self._tmp_vcd_path, os.path.join(self._artifact_dir, "wave.vcd"))
