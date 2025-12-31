#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# Copyright (C) 2025 The SV Tests Authors.
#
# SPDX-License-Identifier: ISC

import os

from arcilator import arcilator as arcilator_runner


class arcilator_top(arcilator_runner):
    """Variant of the arcilator runner that forces `--top=top` when present.

    This is intended to exercise "top-executed" simulation (sv-tests / UVM
    style) rather than the DUT-only fallback used by the default arcilator
    runner for many `:tags: uvm` tests.
    """

    def __init__(self):
        super().__init__()
        self.name = "arcilator-top"

    def get_mode(self, params):
        # Treat tests that whitelist `arcilator` as compatible with this runner
        # variant as well.
        test_features = params["type"].split()
        compatible_runners = params["compatible-runners"].split()

        if "all" not in compatible_runners:
            if self.name not in compatible_runners and "arcilator" not in compatible_runners:
                return None

        modes_sorted = [
            "simulation",
            "simulation_without_run",
            "elaboration",
            "parsing",
            "preprocessing",
        ]
        for mode in modes_sorted:
            if mode in test_features and mode in self.supported_features:
                return mode
        return None

    def _pick_top_module(self, params):
        explicit = params.get("top_module") or ""
        if explicit:
            return explicit

        env_top = os.environ.get("ARCILATOR_TOP") or os.environ.get("CIRCT_VERILOG_TOP")
        if env_top:
            return env_top

        if self._module_defined(params.get("files", []), "top"):
            return "top"

        return self.guess_top_module(params)
