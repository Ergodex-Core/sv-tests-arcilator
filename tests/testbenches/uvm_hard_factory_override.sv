// Copyright (C) 2019-2026  The SymbiFlow Authors.
//
// Use of this source code is governed by a ISC-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/ISC
//
// SPDX-License-Identifier: ISC


/*
:name: uvm_hard_factory_override
:description: Hard UVM test: factory type override and object creation
:tags: uvm uvm-hard
:type: simulation elaboration parsing
:timeout: 300
:unsynthesizable: 1
*/

import uvm_pkg::*;
`include "uvm_macros.svh"

class base_pkt extends uvm_sequence_item;
  `uvm_object_utils(base_pkt)

  function new(string name = "base_pkt");
    super.new(name);
  endfunction
endclass

class derived_pkt extends base_pkt;
  `uvm_object_utils(derived_pkt)

  function new(string name = "derived_pkt");
    super.new(name);
  endfunction
endclass

class env extends uvm_env;
  `uvm_component_utils(env)

  function new(string name, uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    uvm_factory factory;
    base_pkt obj;
    derived_pkt derived;

    phase.raise_objection(this);

    factory = uvm_factory::get();
    factory.set_type_override_by_type(base_pkt::get_type(), derived_pkt::get_type());

    obj = base_pkt::type_id::create("obj", this);
    if (!$cast(derived, obj)) begin
      `uvm_error("RESULT", "Factory override failed");
    end else begin
      `uvm_info("RESULT", "Factory override OK", UVM_LOW);
    end

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
