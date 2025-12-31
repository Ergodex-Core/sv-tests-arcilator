/*
:name: sv_random_m4_selftest
:description: M4 randomization smoke (urandom + randomize constraints + seeding)
:tags: m4 random sv-runtime
:type: simulation
:timeout: 120
:unsynthesizable: 1
:compatible-runners: all
:runner_arcilator_no_class_stubs: 1
*/

class a;
  rand int x;
  constraint c { x > 0 && x < 30; }
endclass

class b;
  rand int x;
endclass

module top;
  `define FAIL(tag) begin \
    $display("FAIL: %s", tag); \
    $display(":assert: (False)"); \
    $finish; \
  end

  initial begin
    int u1, u2;
    a obj;
    b obj2;
    int ok1, ok2, ok3;
    int x1;
    int y;

    // `$urandom(seed)` should be deterministic under the same seed.
    u1 = $urandom(32'h1234);
    u2 = $urandom(32'h1234);
    if (u1 != u2) begin
      `FAIL("$urandom(seed) determinism")
    end

    // Object `srandom` should reset the random stream used by `randomize()`.
    obj = new;
    obj.srandom(20);
    ok1 = obj.randomize();
    x1 = obj.x;
    obj.srandom(20);
    ok2 = obj.randomize();
    if (!(ok1 && ok2 && obj.x == x1 && obj.x > 0 && obj.x < 30)) begin
      `FAIL("randomize + constraint + srandom")
    end

    // Inline constraints should be honored.
    obj2 = new;
    y = 10;
    ok3 = obj2.randomize() with { x > 0; x < y; };
    if (!(ok3 && obj2.x > 0 && obj2.x < y)) begin
      `FAIL("inline constraints with {}")
    end

    $display(":assert: (True)");
    $finish;
  end
endmodule
