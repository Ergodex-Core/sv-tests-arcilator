// sv-tests helper to control UVM end-of-sim behavior.
//
// When enabled, this file is injected by sv-tests/tools/runner for UVM-tagged
// simulation testbenches when SVTESTS_UVM_FORCE_RUN_UNTIL is set.
//
// Purpose: allow extending simulation beyond UVM's default "$finish on phases
// done" behavior to generate longer VCDs for parity checking.

`ifndef SVTESTS_UVM_BIND_MODULE
  `define SVTESTS_UVM_BIND_MODULE top
`endif

`ifndef SVTESTS_UVM_FORCE_RUN_UNTIL
  // Absolute time (in the test's time units) at which to call $finish.
  // 0 means: disable UVM finish_on_completion but do not call $finish here.
  `define SVTESTS_UVM_FORCE_RUN_UNTIL 0
`endif

module svtests_uvm_run_control;
  import uvm_pkg::*;

  // Disable the UVM default "$finish at end of run_test".
  initial begin
    uvm_root root;
    root = uvm_root::get();
    if (root != null) begin
`ifdef UVM_ENABLE_DEPRECATED_API
      root.finish_on_completion = 0;
`else
      root.set_finish_on_completion(0);
`endif
    end
  end

  // Optionally force an end time (constant delay) to keep runs bounded.
  localparam time SVTESTS_FORCE_RUN_UNTIL = `SVTESTS_UVM_FORCE_RUN_UNTIL;
  generate
    if (SVTESTS_FORCE_RUN_UNTIL > 0) begin : gen_force_finish
      initial begin
        #(SVTESTS_FORCE_RUN_UNTIL);
        // Ensure $finish runs after all active events at this time (e.g. clock
        // toggles) so the final VCD sample is not simulator-order dependent.
        #0;
        // UVM should already be done by now for sane settings, but keep this
        // as a safety net so we don't cut off an active run.
        wait (uvm_root::get() != null && uvm_root::get().m_phase_all_done == 1);
        #0;
        $finish;
      end
    end
  endgenerate
endmodule

bind `SVTESTS_UVM_BIND_MODULE svtests_uvm_run_control svtests_uvm_run_control_inst();
