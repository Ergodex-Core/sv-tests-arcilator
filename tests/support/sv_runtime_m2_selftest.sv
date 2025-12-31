/*
:name: sv_runtime_m2_selftest
:description: Exercise SV runtime core (classes, virtual dispatch, strings, dynamic containers)
:tags: m2 sv-runtime
:type: simulation
:timeout: 120
:unsynthesizable: 1
:compatible-runners: all
:runner_arcilator_no_class_stubs: 1
*/

class base_c;
  int x;

  function new(int x0);
    x = x0;
  endfunction

  virtual function int f(int y);
    return x + y;
  endfunction
endclass

class derived_c extends base_c;
  function new(int x0);
    super.new(x0);
  endfunction

  virtual function int f(int y);
    return x + y + 100;
  endfunction
endclass

module top;
  `define FAIL(tag) begin \
    $display("FAIL: %s", tag); \
    $display(":assert: (False)"); \
    $finish; \
  end

  initial begin
    base_c b;
    derived_c d;
    base_c pb;
    int r;

    string s;
    string t;

    int dyn[];
    int q[$];
    int aa[string];

    b = new(5);
    d = new(7);
    pb = d; // upcast

    r = pb.f(3);
    if (r != 110) begin
      `FAIL("virtual dispatch")
    end

    s = "hello";
    if (s != "hello") begin
      `FAIL("string literal assignment/compare")
    end
    if (s.len() != 5) begin
      `FAIL("string len")
    end
    if (s.getc(1) != 8'h65) begin // 'e'
      `FAIL("string getc")
    end
    t = s.substr(1, 3);
    if (t != "ell") begin
      `FAIL("string substr/compare")
    end

    dyn = new[3];
    dyn[0] = 1;
    dyn[1] = 2;
    dyn[2] = 3;
    if (dyn.size() != 3) begin
      `FAIL("dynarray size")
    end
    if (dyn[0] + dyn[1] + dyn[2] != 6) begin
      `FAIL("dynarray contents")
    end

    q.push_back(10);
    q.push_front(5);
    if (q.size() != 2) begin
      `FAIL("queue size")
    end
    if (q.pop_front() != 5) begin
      `FAIL("queue pop_front")
    end
    if (q.pop_back() != 10) begin
      `FAIL("queue pop_back")
    end

    aa["foo"] = 123;
    if (!aa.exists("foo")) begin
      `FAIL("assoc exists")
    end
    if (aa["foo"] != 123) begin
      `FAIL("assoc get")
    end

    $display(":assert: (True)");
    $finish;
  end
endmodule
