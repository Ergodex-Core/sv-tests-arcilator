// sv-tests helper to make class-only UVM "simulation" tests observable in VCDs.
//
// Some UVM-tagged simulation tests contain only class code and a `module top`
// with no ports/nets. When Questa VCD dumping is restricted to the design
// hierarchy under the chosen top, the resulting VCD can be effectively empty
// (no $scope/$var/$enddefinitions), making head-to-head waveform diffs vacuous.
//
// This bound helper instantiates under the test's top module and exposes a
// small, deterministic heartbeat via *ports* so both Questa_vcd and arcilator
// can always emit at least one comparable signal.

`ifndef SVTESTS_UVM_BIND_MODULE
  `define SVTESTS_UVM_BIND_MODULE top
`endif

module svtests_uvm_vcd_smoke(
  output bit [7:0] svtests_vcd_smoke_counter,
  output bit svtests_vcd_smoke_done
);
  initial begin
    svtests_vcd_smoke_counter = 0;
    svtests_vcd_smoke_done = 0;
    repeat (16) begin
      #1;
      svtests_vcd_smoke_counter = svtests_vcd_smoke_counter + 1;
    end
    svtests_vcd_smoke_done = 1;
  end
endmodule

bind `SVTESTS_UVM_BIND_MODULE svtests_uvm_vcd_smoke svtests_uvm_vcd_smoke_inst();

