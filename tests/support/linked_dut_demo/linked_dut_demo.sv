/*
:name: linked_dut_demo
:description: arcilator linked-driver smoke test (custom C++ driver)
:tags: arcilator
:type: simulation
:timeout: 120
:top_module: top
:compatible-runners: arcilator
:files: support/linked_dut_demo/linked_dut_demo.sv
:runner_arcilator_driver: support/linked_dut_demo/driver.cpp
:runner_arcilator_header_basename: linked_dut_demo-arc.h
*/

module top(
  input  logic       clk,
  input  logic       rst,
  input  logic [7:0] in,
  output logic [7:0] out
);
  always_comb begin
    out = in;
  end
endmodule
