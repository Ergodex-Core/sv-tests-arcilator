// sv-tests helper to make UVM simulation results non-vacuous.
//
// This file is injected automatically (see sv-tests/tools/runner) for UVM
// simulation tests that look like real UVM testbenches. It binds into the
// test's top module and emits a sv-tests `:assert:` marker based on the UVM
// report server severity counts at end-of-sim.
//
// NOTE: The `:assert:` expression is evaluated by sv-tests in Python, so we
// print a pure numeric expression like "0 == 0".

`ifndef SVTESTS_UVM_BIND_MODULE
  `define SVTESTS_UVM_BIND_MODULE top
`endif

module svtests_uvm_m0;
  import uvm_pkg::*;

  final begin
    uvm_report_server rs;
    uvm_root root;
    int errors;
    int fatals;
    bit phases_done;
    rs = uvm_report_server::get_server();
    root = uvm_root::get();
    errors = rs.get_severity_count(UVM_ERROR);
    fatals = rs.get_severity_count(UVM_FATAL);
    phases_done = (root != null) ? root.m_phase_all_done : 0;

    $display("SVTESTS_UVM_M0_RAN");
    $display("SVTESTS_UVM_M0_ERRORS=%0d", errors);
    $display("SVTESTS_UVM_M0_FATALS=%0d", fatals);
    $display("SVTESTS_UVM_M0_PHASES_DONE=%0d", phases_done);
    $display(":assert: (%0d == 0) and (%0d == 1)", errors + fatals, phases_done);
  end
endmodule

bind `SVTESTS_UVM_BIND_MODULE svtests_uvm_m0 svtests_uvm_m0_inst();
