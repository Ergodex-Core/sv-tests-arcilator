// Copyright (C) 2019-2026  The SymbiFlow Authors.
//
// Use of this source code is governed by a ISC-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/ISC
//
// SPDX-License-Identifier: ISC


/*
:name: uvm_hard_random_constraints
:description: Hard UVM test: constraint solving on arrays + range checks
:tags: uvm uvm-hard uvm-random
:type: simulation elaboration parsing
:timeout: 300
:unsynthesizable: 1
*/

import uvm_pkg::*;
`include "uvm_macros.svh"

class constrained_vec extends uvm_object;
  `uvm_object_utils(constrained_vec)

  rand int unsigned a0;
  rand int unsigned a1;
  rand int unsigned a2;
  rand int unsigned a3;
  rand int unsigned a4;
  rand int unsigned a5;
  rand int unsigned a6;
  rand int unsigned a7;

  constraint ranges {
    a0 inside {[0:4]};
    a1 inside {[0:4]};
    a2 inside {[0:4]};
    a3 inside {[0:4]};
    a4 inside {[0:4]};
    a5 inside {[0:4]};
    a6 inside {[0:4]};
    a7 inside {[0:4]};
  }
  constraint sum_c {
    (a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7) inside {[10:20]};
  }

  function new(string name = "constrained_vec");
    super.new(name);
  endfunction
endclass

class env extends uvm_env;
  `uvm_component_utils(env)

  constrained_vec v;

  function new(string name, uvm_component parent = null);
    super.new(name, parent);
    v = constrained_vec::type_id::create("v");
  endfunction

  task run_phase(uvm_phase phase);
    int unsigned sum;
    bit ok;

    phase.raise_objection(this);

    ok = v.randomize();
    sum = v.a0 + v.a1 + v.a2 + v.a3 + v.a4 + v.a5 + v.a6 + v.a7;

    if (!ok) begin
      `uvm_error("RESULT", "randomize() returned false");
    end else if (!(sum >= 10 && sum <= 20)) begin
      `uvm_error("RESULT", $sformatf("sum out of range: %0d", sum));
    end else if (!(v.a0 <= 4 && v.a1 <= 4 && v.a2 <= 4 && v.a3 <= 4 &&
                   v.a4 <= 4 && v.a5 <= 4 && v.a6 <= 4 && v.a7 <= 4)) begin
      `uvm_error("RESULT", "element out of range");
    end

    if (uvm_report_server::get_server().get_severity_count(UVM_ERROR) == 0)
      `uvm_info("RESULT", $sformatf("constraints OK (sum=%0d)", sum), UVM_LOW);

    phase.drop_objection(this);
  endtask
endclass

module top;
  env environment;
  initial begin
    environment = new("env");
    run_test();
  end
endmodule
