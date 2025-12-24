/*
:name: arc_tests_snitch_dhrystone
:description: arc-tests Snitch (RISC-V) brought in as a linked DUT; run dhrystone via the upstream C++ driver
:tags: arcilator
:type: simulation
:timeout: 600
:top_module: snitch_th
:compatible-runners: arcilator
:unsynthesizable: 1
:files: ../../arc-tests/snitch/design/snitch_th.sv ../../arc-tests/snitch/design/snitch.sv
:incdirs: ../../arc-tests/snitch/design
:
:runner_arcilator_driver: ../../arc-tests/snitch/snitch-main.cpp
:runner_arcilator_driver_files: ../../arc-tests/snitch/snitch-model-arc.cpp
:runner_arcilator_driver_incdirs: ../../arc-tests ../../arc-tests/snitch
:runner_arcilator_driver_cxxflags: -DRUN_ARC
:runner_arcilator_driver_args: --trace {VCD} ../../arc-tests/benchmarks/dhrystone_rv32i.riscv
:runner_arcilator_header_basename: snitch-arc.h
:runner_arcilator_header_gen_flags: --view-depth 1
:runner_arcilator_circt_ir: hw
:
:runner_arcilator_dut_cache: 1
*/

// Metadata-only wrapper. Sources are listed in :files: above.
