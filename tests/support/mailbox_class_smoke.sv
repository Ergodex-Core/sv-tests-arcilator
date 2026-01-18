/*
:name: mailbox_class_smoke
:description: mailbox of class handles smoke test
:tags: simulation
:type: simulation
:timeout: 60
*/

module top;
  class C;
    int x;
    function new();
      this.x = 0;
    endfunction
  endclass

  mailbox #(C) m;
  C c;

  initial begin
    m = new();
    c = new();
    if (c == null) $fatal(1, "c is null");
    c.x = 42;
    m.put(c);
    begin
      C d;
      m.get(d);
      if (d == null) $fatal(1, "d is null");
      if (d.x != 42) $fatal(1, "bad value %0d", d.x);
    end
    $display("MAILBOX_CLASS_SMOKE_OK");
    $finish;
  end
endmodule
