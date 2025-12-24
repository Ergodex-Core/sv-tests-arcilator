/*
:name: arc_tests_rocket_dhrystone
:description: arc-tests RocketSystem (RISC-V) linked as a real DUT (FIRRTL -> firtool -> arcilator); run dhrystone via the upstream C++ driver
:tags: arcilator
:type: simulation
:timeout: 1200
:top_module: RocketSystem
:compatible-runners: arcilator
:unsynthesizable: 1
:
:runner_arcilator_firrtl: ../../arc-tests/rocket/rocket-small-master.fir.gz
:
:runner_arcilator_flags: --observe-wires=0 --observe-registers=0 --observe-named-values=0
:
:runner_arcilator_driver: support/arc_tests_rocket/rocket_dhrystone_main.cpp
:runner_arcilator_driver_files: ../../arc-tests/rocket/rocket-model-arc.cpp
:runner_arcilator_driver_incdirs: ../../arc-tests/elfio ../../arc-tests/rocket
:runner_arcilator_driver_args: --trace {VCD} --trace-cycles 20000 ../../arc-tests/benchmarks/dhrystone_rv64gcv.riscv
:runner_arcilator_header_basename: rocket-arc.h
:runner_arcilator_header_gen_flags: --view-depth 1
:
:runner_arcilator_dut_cache: 1
*/

// Metadata-only wrapper. Real DUT + driver are provided via runner metadata.
