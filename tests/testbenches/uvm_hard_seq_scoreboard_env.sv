// Copyright (C) 2019-2026  The SymbiFlow Authors.
//
// Use of this source code is governed by a ISC-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/ISC
//
// SPDX-License-Identifier: ISC


/*
:name: uvm_hard_seq_scoreboard_env
:description: Hard UVM test: sequence->driver->DUT->monitor->scoreboard ordering
:tags: uvm uvm-hard
:type: simulation elaboration parsing
:timeout: 300
:unsynthesizable: 1
*/

import uvm_pkg::*;
`include "uvm_macros.svh"

interface input_if(input clk);
  logic       valid;
  logic [7:0] data;
  modport port(input clk, data, valid);
endinterface

interface output_if(input clk);
  logic       valid;
  logic [7:0] data;
  modport port(input clk, output data, output valid);
endinterface

module dut(input_if.port in, output_if.port out);
  always @(posedge in.clk) begin
    out.data  <= in.data;
    out.valid <= in.valid;
  end
endmodule

class packet_in extends uvm_sequence_item;
  rand logic [7:0] data;

  `uvm_object_utils_begin(packet_in)
    `uvm_field_int(data, UVM_ALL_ON | UVM_HEX)
  `uvm_object_utils_end

  function new(string name = "packet_in");
    super.new(name);
  endfunction
endclass

class packet_out extends uvm_sequence_item;
  logic [7:0] data;

  `uvm_object_utils_begin(packet_out)
    `uvm_field_int(data, UVM_ALL_ON | UVM_HEX)
  `uvm_object_utils_end

  function new(string name = "packet_out");
    super.new(name);
  endfunction
endclass

class seq_in extends uvm_sequence #(packet_in);
  `uvm_object_utils(seq_in)

  function new(string name = "seq_in");
    super.new(name);
  endfunction

  task body;
    packet_in pkt;
    for (int unsigned i = 0; i < 5; i++) begin
      pkt = packet_in::type_id::create($sformatf("pkt_%0d", i));
      start_item(pkt);
      pkt.data = 8'h10 + i[7:0];
      finish_item(pkt);
    end
  endtask
endclass

class sequencer extends uvm_sequencer #(packet_in);
  `uvm_component_utils(sequencer)

  function new(string name = "sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass

class driver extends uvm_driver #(packet_in);
  `uvm_component_utils(driver)

  virtual input_if vif;

  function new(string name = "driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    assert(uvm_resource_db#(virtual input_if)::read_by_name(
        "env", "input_if", vif));
  endfunction

  virtual task run_phase(uvm_phase phase);
    vif.valid <= 0;
    vif.data  <= 0;

    // Avoid time-0 scheduling corner cases: wait for the clock to start.
    repeat (2) @(posedge vif.clk);

    forever begin
      seq_item_port.get(req);
      @(posedge vif.clk);
      vif.data  <= req.data;
      vif.valid <= 1;
      @(posedge vif.clk);
      vif.valid <= 0;
    end
  endtask
endclass

class monitor extends uvm_monitor;
  `uvm_component_utils(monitor)

  virtual output_if vif;

  uvm_analysis_port #(packet_out) ap;

  function new(string name, uvm_component parent = null);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    assert(uvm_resource_db#(virtual output_if)::read_by_name(
        "env", "output_if", vif));
  endfunction

  virtual task run_phase(uvm_phase phase);
    packet_out pkt;
    forever begin
      @(posedge vif.clk);
      if (!vif.valid)
        continue;
      pkt = packet_out::type_id::create("pkt");
      pkt.data = vif.data;
      ap.write(pkt);
    end
  endtask
endclass

class scoreboard extends uvm_scoreboard;
  typedef scoreboard this_type;
  `uvm_component_utils(this_type)

  uvm_analysis_imp #(packet_out, this_type) from_dut;

  int unsigned expected_base;
  int unsigned expected_count;
  int unsigned seen;
  event done;

  function new(string name, uvm_component parent = null);
    super.new(name, parent);
    from_dut = new("from_dut", this);
    expected_base = 8'h10;
    expected_count = 5;
    seen = 0;
  endfunction

  function void set_expected(int unsigned base, int unsigned count);
    expected_base = base;
    expected_count = count;
    seen = 0;
  endfunction

  virtual function void write(packet_out got);
    int unsigned exp;
    exp = expected_base + seen;
    if (got.data !== exp[7:0]) begin
      `uvm_error("RESULT", $sformatf("Mismatch got=%0d exp=%0d", got.data, exp));
      return;
    end
    seen++;
    if (seen >= expected_count)
      ->done;
  endfunction
endclass

class env extends uvm_env;
  `uvm_component_utils(env)

  seq_in seq;
  sequencer sqr;
  driver drv;
  monitor mon;
  scoreboard sb;

  function new(string name, uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    seq = seq_in::type_id::create("seq", this);
    sqr = sequencer::type_id::create("sqr", this);
    drv = driver::type_id::create("drv", this);
    mon = monitor::type_id::create("mon", this);
    sb  = scoreboard::type_id::create("sb", this);
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
    mon.ap.connect(sb.from_dut);
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);

    sb.set_expected(8'h10, 5);

    seq.start(sqr);
    @(sb.done);

    `uvm_info("RESULT", $sformatf("Matched %0d packets", sb.seen), UVM_LOW);
    phase.drop_objection(this);
  endtask
endclass

module top;
  logic clk;
  env environment;

  input_if in(clk);
  output_if out(clk);
  dut d(in, out);

  always #5 clk = !clk;

  initial begin
    clk = 0;
    environment = new("env");
    uvm_resource_db#(virtual input_if)::set("env", "input_if", in);
    uvm_resource_db#(virtual output_if)::set("env", "output_if", out);
    run_test();
  end
endmodule
