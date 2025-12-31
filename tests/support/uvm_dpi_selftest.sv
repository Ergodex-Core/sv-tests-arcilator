/*
:name: uvm_dpi_selftest
:description: Exercise UVM DPI hooks (regex + uvm_hdl_check_path)
:tags: uvm
:type: simulation
:timeout: 120
:unsynthesizable: 1
:compatible-runners: arcilator
:top_module: top
:runner_arcilator_uvm_no_dpi: 0
:runner_arcilator_flags: --observe-memories
*/

import uvm_pkg::*;

module child(
  input  logic       clk,
  output logic [7:0] reg8_o,
  output logic [7:0] mem2_o
);
  logic [7:0] reg8;
  logic [7:0] mem [0:3];

  always_ff @(posedge clk) begin
    reg8 <= reg8 + 8'h1;
    mem[0] <= mem[0] + 8'h1;
    mem[2] <= mem[2] + 8'h1;
  end

  assign reg8_o = reg8;
  assign mem2_o = mem[2];
endmodule

module top(
  input  logic       clk,
  output logic [7:0] reg8_o,
  output logic [7:0] mem2_o
);
  child u(.clk(clk), .reg8_o(reg8_o), .mem2_o(mem2_o));

  initial begin
    // Wait until after the driver has constructed the DUT and installed the
    // arcilator→UVM bridge hooks.
    @(posedge clk);

    if (uvm_re_match("/^foo.*$/", "foobar") != 0)
      $error("uvm_re_match glob mismatch :assert: (False)");
    if (uvm_re_match("/^foo.*$/", "bar") == 0)
      $error("uvm_re_match glob false-positive :assert: (False)");

    if (!uvm_hdl_check_path("u.reg8_o"))
      $error("uvm_hdl_check_path failed :assert: (False)");
    if (!uvm_hdl_check_path("u.reg8_o[2]"))
      $error("uvm_hdl_check_path bit-select failed :assert: (False)");
    if (!uvm_hdl_check_path("u.reg8_o[7:4]"))
      $error("uvm_hdl_check_path part-select failed :assert: (False)");
  end
endmodule
