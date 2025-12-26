/*
:name: uvm_hdl_selftest
:description: arcilator-generated uvm_hdl_* selftest (path normalization, bit/part selects, memory indexing)
:tags: uvm
:type: simulation
:timeout: 120
:top_module: top
:runner_arcilator_flags: --observe-memories
*/

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
endmodule
