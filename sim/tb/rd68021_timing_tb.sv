// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68021

// RD68021 -- the AC-timing event log.
//
// Emits times and nothing else. No testbench here knows what a specification is;
// the limits live in tools/timing/specs.py and the reading of the figures in
// tools/timing/anchors.py. That separation is what lets a wrong anchor be fixed
// with a one-line edit and a re-analysis in milliseconds instead of a
// re-simulation -- and it is what would let a second core, in another language,
// be judged by exactly the same code.
//
// An RTL model has no pad delays, so every pin moves exactly on a clock edge.
// What is recorded is therefore which edge, and in which direction: the analysis
// adds the unknown pad delay to it and asks whether any assignment of those
// delays fits inside Section 10.
//
// Output format, one line per transition:
//
//     S <scenario>
//     T <time_ns> <R|F> <event>
//
// The event vocabulary is fixed in tools/timing/anchors.py and nothing may invent
// one that is not in that list.

`timescale 1ns / 1ps

module rd68021_timing_tb;

`include "rd68021_bus_harness.svh"

  integer      log;
  string       logname;
  logic [39:0] got;
  int unsigned cycles;
  int unsigned t;
  logic        recording;
  string       edge_c;

  // The previous snapshot, so that a transition is a difference.
  logic [31:0] p_a;
  logic  [2:0] p_fc;
  logic  [1:0] p_siz;
  logic        p_rmc, p_aoe;
  logic [31:0] p_d;
  logic        p_doe;
  logic        p_ecs, p_ocs, p_as, p_ds, p_rw, p_dben, p_bg, p_asoe;
  logic        primed;

  task automatic emit(input string name);
    if (recording) $fdisplay(log, "T %0.3f %s %s", $realtime, edge_c, name);
  endtask

  task automatic snap(input string which);
    edge_c = which;
    if (primed) begin
      // The address group -- address, function codes, SIZ and RMC move together
      // and are judged together by specifications 6, 7, 8, 11 and 13.
      if (a_oe && !p_aoe) begin
        emit("addr.valid");
      end else if (a_oe && p_aoe &&
                   ({a_o, fc_o, siz_o, rmc_n_o} !== {p_a, p_fc, p_siz, p_rmc})) begin
        emit("addr.invalid");
        emit("addr.valid");
      end else if (!a_oe && p_aoe) begin
        emit("addr.invalid");
        emit("addr.hiz");
      end

      // The data bus on a write.
      if (d_oe && !p_doe) begin
        emit("dout.valid");
      end else if (d_oe && p_doe && (d_o !== p_d)) begin
        emit("dout.invalid");
        emit("dout.valid");
      end else if (!d_oe && p_doe) begin
        emit("dout.invalid");
        emit("dout.hiz");
      end

      if (!ecs_n_o &&  p_ecs) emit("ecs.assert");
      if ( ecs_n_o && !p_ecs) emit("ecs.negate");
      if (!ocs_n_o &&  p_ocs) emit("ocs.assert");
      if ( ocs_n_o && !p_ocs) emit("ocs.negate");
      if (!as_n_o  &&  p_as)  emit("as.assert");
      if ( as_n_o  && !p_as)  emit("as.negate");
      if (!ds_n_o  &&  p_ds)  emit("ds.assert");
      if ( ds_n_o  && !p_ds)  emit("ds.negate");

      if (rw_o !== p_rw) begin
        emit("rw.change");
        if (rw_o) emit("rw.high");
        else      emit("rw.low");
      end

      if (!dben_n_o && !p_dben) emit("dben.assert");
      if ( dben_n_o &&  p_dben) emit("dben.negate");

      if (!bg_n_o &&  p_bg) emit("bg.assert");
      if ( bg_n_o && !p_bg) emit("bg.negate");

      // The control group goes high impedance only on relinquish.
      if (!as_oe && p_asoe) emit("ctl.hiz");
    end

    p_a = a_o; p_fc = fc_o; p_siz = siz_o; p_rmc = rmc_n_o; p_aoe = a_oe;
    p_d = d_o; p_doe = d_oe;
    p_ecs = ecs_n_o; p_ocs = ocs_n_o; p_as = as_n_o; p_ds = ds_n_o;
    p_rw = rw_o; p_dben = !dben_n_o; p_bg = bg_n_o; p_asoe = as_oe;
    primed = 1'b1;
  endtask

  // Sample SNAP ns after every edge: late enough that the edge has settled,
  // early enough that nothing else has happened.
  always @(posedge clk) begin #(SNAP); snap("R"); end
  always @(negedge clk) begin #(SNAP); snap("F"); end

  task automatic scenario(input string name);
    $fdisplay(log, "S %s", name);
    recording = 1'b1;
  endtask

  task automatic quiesce();
    recording = 1'b0;
    repeat (6) @(posedge clk);
  endtask

  initial begin
    if (!$value$plusargs("log=%s", logname)) logname = "build/timing-events.log";
    log       = $fopen(logname, "w");
    recording = 1'b0;
    primed    = 1'b0;
    reset_dut();
    for (t = 0; t < 4096; t = t + 1) begin
      s32.mem[t] = 8'h10 + t[7:0];
      s8.mem[t]  = 8'h10 + t[7:0];
    end

    // -------------------------------------------------------------------
    // Reads. The four-cycle burst on the 8-bit port is what makes
    // specifications 15, 15A and 10B measure their real minimum: back to back
    // within one operand is the tightest the bus ever gets.
    // -------------------------------------------------------------------
    scenario("read");
    op_read(32'h2000_0100, 4, got, cycles);   // four cycles, back to back
    op_read(32'h0000_0100, 4, got, cycles);   // one cycle
    op_read(32'h0000_0104, 4, got, cycles);
    quiesce();

    // -------------------------------------------------------------------
    // Writes.
    // -------------------------------------------------------------------
    scenario("write");
    op_write(32'h2000_0200, 4, 40'h00_A1B2C3D4, cycles);
    op_write(32'h0000_0200, 4, 40'h00_DEADBEEF, cycles);
    op_write(32'h0000_0204, 2, 40'h00_0000_1234, cycles);
    quiesce();

    // -------------------------------------------------------------------
    // Read, write, read. R/W only transitions when a write follows a read or
    // the other way about (UM 5.1.1), so specifications 17 and 46 have nothing
    // to measure in a log that goes one way.
    // -------------------------------------------------------------------
    scenario("mixed");
    op_read (32'h0000_0300, 4, got, cycles);
    op_write(32'h0000_0300, 4, 40'h00_01020304, cycles);
    op_read (32'h0000_0300, 4, got, cycles);
    op_write(32'h0000_0308, 4, 40'h00_05060708, cycles);
    quiesce();

    // -------------------------------------------------------------------
    // Arbitration, twice, so that BG has both a width asserted and a width
    // negated to measure.
    // -------------------------------------------------------------------
    scenario("arb");
    for (t = 0; t < 2; t = t + 1) begin
      @(posedge clk);
      br_drv = 1'b1;
      repeat (4) @(posedge clk);
      bgack_drv = 1'b1;
      @(posedge clk);
      br_drv = 1'b0;
      repeat (6) @(posedge clk);
      bgack_drv = 1'b0;
      repeat (6) @(posedge clk);
    end
    quiesce();

    $fclose(log);
    $display("PASS: rd68021_timing_tb (event log written)");
    $finish;
  end

  initial begin
    #2_000_000;
    $display("FAIL: rd68021_timing_tb timed out");
    $finish;
  end

endmodule
