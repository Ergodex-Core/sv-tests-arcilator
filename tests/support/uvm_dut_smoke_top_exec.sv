/*
:name: uvm_dut_smoke_top_exec
:description: UVM top-executed smoke with a tiny DUT (SV->VCD pipeline proof)
:tags: uvm uvm-classes proof dut
:type: simulation
:timeout: 120
:unsynthesizable: 1
:compatible-runners: all
:runner_arcilator_no_class_stubs: 1
*/

import uvm_pkg::*;

module dut(
  input  logic       clk,
  input  logic       rst,
  input  logic [7:0] in,
  output logic [7:0] out
);
  always_ff @(posedge clk) begin
    if (rst)
      out <= '0;
    else
      out <= in;
  end
endmodule

class simple_test extends uvm_test;
  `uvm_component_utils(simple_test)

  function new(string name = "simple_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info("RESULT", "UVM DUT smoke reached run_phase (shim OK)", UVM_LOW);
    phase.drop_objection(this);
  endtask
endclass

module top;
  logic clk;
  logic rst;
  logic [7:0] in;
  logic [7:0] out;

  dut d(.clk(clk), .rst(rst), .in(in), .out(out));

  always begin
    #5 clk = 0;
    #5 clk = 1;
  end

  initial begin
    clk = 0;
    rst = 1;
    in = 0;

    #20 rst = 0;
    #10 in = 8'h01;
    #10 in = 8'h02;
    #10 in = 8'h03;
    #10 in = 8'h04;
  end

  initial begin
    run_test("simple_test");
  end
endmodule
