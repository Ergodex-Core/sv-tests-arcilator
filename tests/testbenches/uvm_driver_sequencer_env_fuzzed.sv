// Copyright (C) 2019-2021  The SymbiFlow Authors.
//
// Use of this source code is governed by a ISC-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/ISC
//
// SPDX-License-Identifier: ISC


/*
:name: uvm_driver_sequencer_env_fuzzed
:description: deterministic "fuzzed" variant of uvm_driver_sequencer_env (multi-transaction + backpressure + monitor+scoreboard)
:tags: uvm uvm-classes uvm-scoreboards
:type: simulation
:timeout: 300
:unsynthesizable: 1
*/

import uvm_pkg::*;
`include "uvm_macros.svh"

`define NUM_PKTS 32
`define SEED_TXN 32'hc0ffee01
`define SEED_RDY 32'hc0ffee55

`ifndef SVTESTS_UVM_BIND_MODULE
  `define SVTESTS_UVM_BIND_MODULE top
`endif

function automatic logic [31:0] lfsr32_next(logic [31:0] s);
    // Primitive polynomial: x^32 + x^22 + x^2 + x + 1
    logic feedback;
    feedback = s[31] ^ s[21] ^ s[1] ^ s[0];
    return {s[30:0], feedback};
endfunction

interface input_if(input logic clk, input logic rst_n);
    logic        valid;
    logic        ready;
    logic [7:0]  data;

    modport dut(input clk, input rst_n, input valid, input data, output ready);
endinterface

interface output_if(input logic clk, input logic rst_n);
    logic        valid;
    logic        ready;
    logic [7:0]  data;

    modport dut(input clk, input rst_n, input ready, output valid, output data);
endinterface

module dut(input_if.dut in, output_if.dut out);
    logic [7:0] fifo [0:`NUM_PKTS-1];
    logic [5:0] wptr;
    logic [5:0] rptr;

    always @(posedge in.clk) begin
        if (!in.rst_n) begin
            wptr <= '0;
            rptr <= '0;
            in.ready <= 1'b0;
            out.valid <= 1'b0;
            out.data  <= 8'h00;
        end else begin
            logic push;
            logic pop;
            logic [5:0] wptr_next;
            logic [5:0] rptr_next;
            logic have_next;

            push = in.valid && (wptr < `NUM_PKTS);
            pop = out.valid && out.ready;

            in.ready <= (wptr < `NUM_PKTS);

            if (push)
                fifo[wptr] <= in.data;

            wptr_next = wptr + push;
            rptr_next = rptr + pop;
            have_next = (rptr_next < wptr_next);

            out.valid <= have_next;
            if (have_next) begin
                // If the FIFO was empty (or drained) and we push this cycle,
                // the next element is the one we're writing now.
                if (push && (rptr_next == wptr))
                    out.data <= in.data;
                else
                    out.data <= fifo[rptr_next];
            end else begin
                out.data <= 8'h00;
            end

            wptr <= wptr_next;
            rptr <= rptr_next;
        end
    end
endmodule

class packet_in extends uvm_sequence_item;
    logic [7:0] data;
    int unsigned idle_cycles;

    `uvm_object_utils_begin(packet_in)
        `uvm_field_int(data, UVM_ALL_ON | UVM_HEX)
        `uvm_field_int(idle_cycles, UVM_ALL_ON | UVM_DEC)
    `uvm_object_utils_end

    function new(string name = "packet_in");
        super.new(name);
    endfunction: new
endclass

class sequence_in extends uvm_sequence #(packet_in);
    `uvm_object_utils(sequence_in)

    function new(string name = "sequence_in");
        super.new(name);
    endfunction: new

    task body;
        logic [31:0] state;
        packet_in packet;

        state = `SEED_TXN;
        repeat (`NUM_PKTS) begin
            state = lfsr32_next(state);
            packet = packet_in::type_id::create($sformatf("pkt_%0d", state[15:8]));
            start_item(packet);
            packet.data = state[7:0];
            packet.idle_cycles = state[10:8] % 4; // 0..3 cycles of deterministic idle
            finish_item(packet);
        end
    endtask: body
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
        // Deterministic drive: insert per-item idle cycles and drive a
        // single-cycle `valid` pulse per item. The DUT is buffered, so this
        // avoids simulator-dependent ready/valid ordering effects.
        vif.valid <= 1'b0;
        vif.data  <= 8'h00;

        // Wait for reset deassert.
        do @(posedge vif.clk); while (!vif.rst_n);

        forever begin
            seq_item_port.get(req);
            repeat (req.idle_cycles + 1) @(posedge vif.clk);

            vif.valid <= 1'b1;
            vif.data  <= req.data;

            @(posedge vif.clk);
            vif.valid <= 1'b0;
            vif.data  <= 8'h00;
        end
    endtask
endclass

class packet_out extends uvm_sequence_item;
    logic [7:0] data;

    `uvm_object_utils_begin(packet_out)
        `uvm_field_int(data, UVM_ALL_ON | UVM_HEX)
    `uvm_object_utils_end

    function new(string name = "packet_out");
        super.new(name);
    endfunction: new
endclass

class monitor extends uvm_monitor;
    `uvm_component_utils(monitor)
    virtual output_if vif;
    uvm_analysis_port #(packet_out) item_collected_port;

    function new(string name = "monitor", uvm_component parent = null);
        super.new(name, parent);
        item_collected_port = new("item_collected_port", this);
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
            if (!vif.rst_n)
                continue;
            if (vif.valid && vif.ready) begin
                pkt = packet_out::type_id::create("pkt", this);
                pkt.data = vif.data;
                item_collected_port.write(pkt);
            end
        end
    endtask
endclass

class scoreboard extends uvm_scoreboard;
    typedef scoreboard this_type;
    `uvm_component_utils(this_type)

    uvm_analysis_imp #(packet_out, this_type) from_dut;
    int unsigned seen;
    int unsigned match;
    int unsigned mismatch;
    logic [31:0] exp_state;
    event done;

    function new(string name = "scoreboard", uvm_component parent = null);
        super.new(name, parent);
        from_dut = new("from_dut", this);
        seen = 0;
        match = 0;
        mismatch = 0;
        exp_state = `SEED_TXN;
    endfunction

    virtual function void write(packet_out rec);
        logic [7:0] exp;
        exp_state = lfsr32_next(exp_state);
        exp = exp_state[7:0];
        if (rec.data == exp) begin
            match++;
        end else begin
            mismatch++;
            `uvm_error("RESULT",
                $sformatf("Mismatch pkt[%0d] got=%0h expected=%0h", seen, rec.data, exp));
        end
        seen++;
        if (seen == `NUM_PKTS) begin
            ->done;
        end
    endfunction
endclass

class env extends uvm_env;
    `uvm_component_utils(env)

    sequence_in seq;
    sequencer sqr;
    driver drv;
    monitor mon;
    scoreboard scb;

    function new(string name = "env", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        seq = sequence_in::type_id::create("seq", this);
        sqr = sequencer::type_id::create("sqr", this);
        drv = driver::type_id::create("drv", this);
        mon = monitor::type_id::create("mon", this);
        scb = scoreboard::type_id::create("scb", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
        mon.item_collected_port.connect(scb.from_dut);
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        fork
            seq.start(sqr);
        join_none
        @(scb.done);
        phase.drop_objection(this);
    endtask

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        if (scb.mismatch == 0 && scb.seen == `NUM_PKTS) begin
            `uvm_info("RESULT",
                $sformatf("PASS match=%0d mismatch=%0d", scb.match, scb.mismatch),
                UVM_LOW);
        end else begin
            `uvm_error("RESULT",
                $sformatf("FAIL match=%0d mismatch=%0d seen=%0d", scb.match, scb.mismatch, scb.seen));
        end
    endfunction
endclass

module top;
    logic clk;
    logic rst_n;
    env environment;

    input_if in(clk, rst_n);
    output_if out(clk, rst_n);
    dut d(in, out);
    sink s(out);

    always #5 clk = !clk;
    logic        in_ready_sampled;

    // Sample `in.ready` away from posedges to avoid simulator-order
    // differences when multiple posedge blocks update/read ready/valid in the
    // same timestep.
    always @(negedge clk) begin
        if (!rst_n)
            in_ready_sampled <= 1'b0;
        else
            in_ready_sampled <= in.ready;
    end

    initial begin
        clk = 0;
        rst_n = 0;
        in.valid = 0;
        in.data  = 0;

        environment = new("env");
        uvm_resource_db#(virtual input_if)::set("env", "input_if", in);
        uvm_resource_db#(virtual output_if)::set("env", "output_if", out);
        run_test();
    end

    // Deterministic reset: release after a few edges so UVM components can initialize.
    initial begin
        // Deassert reset *between* posedges to avoid simulator-dependent
        // ordering when a posedge and a `#N` wakeup happen at the same time.
        // For a 10ns clock period (posedge at t=5,15,25,35,...), deassert at t=26.
        #26;
        rst_n = 1;
    end
endmodule

module sink(output_if out);
    logic [31:0] ready_state;

    // Deterministic backpressure generator for out.ready.
    always @(posedge out.clk) begin
        if (!out.rst_n) begin
            ready_state <= `SEED_RDY;
            out.ready <= 1'b0;
        end else begin
            out.ready <= ready_state[0] | ready_state[1];
            ready_state <= {ready_state[30:0], ready_state[31] ^ ready_state[21] ^ ready_state[1] ^ ready_state[0]};
        end
    end
endmodule

// VCD probe: Questa_vcd dumps "ports only", so bind a small probe module with
// explicit ports wired to the interesting internal signals.
module uvm_fuzz_vcd_probe(
    input logic       clk,
    input logic       rst_n,
    input logic       in_valid,
    input logic [7:0] in_data,
    input logic       in_ready_sampled,
    input logic       out_valid,
    input logic [7:0] out_data,
    input logic       out_ready
);
endmodule

bind `SVTESTS_UVM_BIND_MODULE uvm_fuzz_vcd_probe uvm_fuzz_vcd_probe_inst(
    .clk(clk),
    .rst_n(rst_n),
    .in_valid(in.valid),
    .in_data(in.data),
    .in_ready_sampled(in_ready_sampled),
    .out_valid(out.valid),
    .out_data(out.data),
    .out_ready(out.ready)
);
