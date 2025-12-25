/*
:name: sys_tasks_demo
:description: demo $display/$error/$fatal for arcilator pipeline
:type: elaboration parsing
:tags: debug
:timeout: 60
*/

module sys_tasks_demo(
    input logic clk,
    input logic [7:0] a,
    output logic [7:0] y
);
  always_ff @(posedge clk) begin
    $display("tick a=%0d", a);
    if (a == 8'h2a) $error("saw 0x2a");
    if (a == 8'h63) $fatal(1, "saw 0x63");
  end

  assign y = ~a;
endmodule
