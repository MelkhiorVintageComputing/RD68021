// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68021

// RD68021 -- the bus cycle on the manual's own ruler.
//
// UM 5.3 measures a bus cycle in states, one per CLK half period, and figures 10-3
// and 10-4 draw every pin against them. This testbench indexes its observations the
// same way: tick 0 is the rising edge that enters S0, tick 1 the falling edge that
// enters S1, and so on to tick 6, the rising edge that ends S5. Pins are sampled
// SNAP ns after each edge.
//
// Two kinds of check, and the second is the one that would catch a design that got
// the pattern right and the timing wrong:
//
//   1. The pattern, tick by tick, against the state descriptions in UM 5.3.1 and
//      5.3.2 -- which say exactly which signal moves in which state.
//
//   2. The widths and separations the pattern implies, in nanoseconds, against the
//      minima Section 10 prints for the 16.67 MHz grade. A half clock is 30 ns
//      there, so every one of these is a real number and not a tautology.
//
// This is not the AC-timing conformance analysis, which is a different thing: an
// RTL model has no pad delays, so section 10's limits become a feasibility question
// rather than a measurement. That is `make timing`, in M3. What is checked here is
// the part that does not need pad delays -- the distances between clock edges.

`timescale 1ns / 1ps

module bus_ruler_tb;

`include "rd68021_bus_harness.svh"

  localparam int NTICK = 7;

  // Recorded pin levels, tick by tick. Packed, with tick 0 in the most significant
  // bit so that %b prints them left to right in time order -- and because iverilog
  // will not pass an unpacked array to a task.
  logic [NTICK-1:0] ecs_r, ocs_r, as_r, ds_r, dben_r, rw_r, aoe_r, doe_r;
  logic [1:0] siz_r [0:NTICK-1];

  int unsigned t;
  logic [39:0] got;
  int unsigned cycles;
  string what;

  // Edge times, for the width checks.
  realtime t_as_lo, t_as_hi, t_ds_lo, t_ds_hi;
  realtime t_ecs_lo, t_ecs_hi, t_dben_lo, t_dben_hi, t_rw, t_dout;

  task automatic record();
    for (t = 0; t < NTICK; t = t + 1) begin
      if (t == 0) @(negedge ecs_n_o);   // the rising edge that enters S0
      else        @(clk);
      #(SNAP);
      ecs_r[NTICK-1-t]  = ecs_n_o;
      ocs_r[NTICK-1-t]  = ocs_n_o;
      as_r[NTICK-1-t]   = as_n_o;
      ds_r[NTICK-1-t]   = ds_n_o;
      dben_r[NTICK-1-t] = dben_n_o;    // the pin: active low, UM table 3-2
      rw_r[NTICK-1-t]   = rw_o;
      aoe_r[NTICK-1-t]  = a_oe;
      doe_r[NTICK-1-t]  = d_oe;
      siz_r[t]          = siz_o;
    end
  endtask

  task automatic expect_pattern(input string name, input logic [NTICK-1:0] v,
                                input logic [NTICK-1:0] want);
    $sformat(what, "%s over S0..S5: want %b, got %b", name, want, v);
    check(v === want, what);
  endtask

  // Timestamp collectors, armed by the test and read after it.
  always @(negedge as_n_o)   t_as_lo   = $realtime;
  always @(posedge as_n_o)   t_as_hi   = $realtime;
  always @(negedge ds_n_o)   t_ds_lo   = $realtime;
  always @(posedge ds_n_o)   t_ds_hi   = $realtime;
  always @(negedge ecs_n_o)  t_ecs_lo  = $realtime;
  always @(posedge ecs_n_o)  t_ecs_hi  = $realtime;
  always @(negedge dben_n_o) t_dben_lo = $realtime;
  always @(posedge dben_n_o) t_dben_hi = $realtime;
  always @(rw_o)             t_rw      = $realtime;
  always @(posedge d_oe)     t_dout    = $realtime;

  task automatic expect_ge(input string name, input realtime got_ns,
                           input real want_ns);
    $sformat(what, "%s: %0.1f ns, specification minimum %0.1f ns at 16.67 MHz",
             name, got_ns, want_ns);
    check(got_ns >= want_ns, what);
  endtask

  initial begin
    $display("bus_ruler_tb: the bus cycle against UM 5.3 and figures 10-3, 10-4");
    reset_dut();
    for (t = 0; t < 4096; t = t + 1) s32.mem[t] = 8'h10 + t[7:0];

    // ---------------------------------------------------------------------
    // Read, 32-bit port, no wait states. UM 5.3.1.
    //
    //   S0  ECS and OCS asserted; address, FC, SIZ valid; R/W high; DBEN negated
    //   S1  AS asserted, DS asserted, ECS and OCS negated
    //   S2  DBEN asserted
    //   S3  DSACK sampled at the end of S2
    //   S4  data latched at the end of S4
    //   S5  AS, DS and DBEN negated; address held valid
    //   --  the address group released on the rising edge that ends S5
    // ---------------------------------------------------------------------
    fork
      record();
      op_read(32'h0000_0100, 4, got, cycles);
    join

    check(got[31:0] === 32'h10111213, "read: the long word at $100");
    check(cycles == 1, "read: one bus cycle");

    //                       tick  0123456
    expect_pattern("read ECS", ecs_r, 7'b0111111);
    expect_pattern("read OCS", ocs_r, 7'b0111111);
    expect_pattern("read AS", as_r, 7'b1000011);
    expect_pattern("read DS", ds_r, 7'b1000011);
    expect_pattern("read DBEN", dben_r, 7'b1100011);
    expect_pattern("read R/W", rw_r, 7'b1111111);
    expect_pattern("read A_OE", aoe_r, 7'b1111110);
    expect_pattern("read D_OE", doe_r, 7'b0000000);

    check(siz_r[0] == 2'b00 && siz_r[1] == 2'b00 && siz_r[4] == 2'b00,
          "read SIZ is long word throughout the cycle");

    expect_ge("read, specification 10, ECS width asserted",
              t_ecs_hi - t_ecs_lo, 20.0);
    expect_ge("read, specification 14, AS and DS width asserted",
              t_as_hi - t_as_lo, 100.0);
    expect_ge("read, specification 45, DBEN width asserted",
              t_dben_hi - t_dben_lo, 60.0);
    expect_ge("read, specification 11, address valid to AS asserted",
              t_as_lo - t_ecs_lo, 15.0);

    // ---------------------------------------------------------------------
    // Write, 32-bit port, no wait states. UM 5.3.2.
    //
    //   S0  ECS and OCS asserted; address, FC, SIZ valid; R/W driven low
    //   S1  AS asserted, DBEN asserted, ECS and OCS negated
    //   S2  the data placed on D31-D0; DSACK sampled at the end of S2
    //   S3  DS asserted
    //   S4  nothing
    //   S5  AS and DS negated; address, data, R/W, SIZ, FC and DBEN held valid
    //   --  data and DBEN released on the rising edge that ends S5
    // ---------------------------------------------------------------------
    fork
      record();
      op_write(32'h0000_0200, 4, 40'h00_DEADBEEF, cycles);
    join

    check(cycles == 1, "write: one bus cycle");
    check({s32.mem[32'h200], s32.mem[32'h201], s32.mem[32'h202], s32.mem[32'h203]}
          === 32'hDEADBEEF, "write: the long word at $200");

    //                        tick  0123456
    expect_pattern("write ECS", ecs_r, 7'b0111111);
    expect_pattern("write OCS", ocs_r, 7'b0111111);
    expect_pattern("write AS", as_r, 7'b1000011);
    expect_pattern("write DS", ds_r, 7'b1110011);
    expect_pattern("write DBEN", dben_r, 7'b1000001);
    expect_pattern("write R/W", rw_r, 7'b0000000);
    expect_pattern("write A_OE", aoe_r, 7'b1111110);
    expect_pattern("write D_OE", doe_r, 7'b0011110);

    expect_ge("write, specification 14A, DS width asserted",
              t_ds_hi - t_ds_lo, 40.0);
    expect_ge("write, specification 45, DBEN width asserted",
              t_dben_hi - t_dben_lo, 120.0);
    expect_ge("write, specification 22, R/W low to DS asserted",
              t_ds_lo - t_rw, 75.0);
    expect_ge("write, specification 26, data-out valid to DS asserted",
              t_ds_lo - t_dout, 15.0);
    expect_ge("write, specification 44, R/W low to DBEN asserted",
              t_dben_lo - t_rw, 15.0);

    // ---------------------------------------------------------------------
    // Two reads back to back. Specification 15 is the only width that needs a
    // second cycle to measure: AS and DS negated between them.
    // ---------------------------------------------------------------------
    begin
      realtime as_hi_first;
      fork
        begin
          @(posedge as_n_o);
          as_hi_first = $realtime;
          @(negedge as_n_o);
          expect_ge("specification 15, AS width negated between cycles",
                    $realtime - as_hi_first, 40.0);
        end
        op_read(32'h0000_0301, 4, got, cycles);   // misaligned: two bus cycles
      join
      check(cycles == 2, "misaligned long word on a 32-bit port: two bus cycles");
      check(got[31:0] === 32'h11121314, "misaligned long word: the bytes at $301");
    end

    // ---------------------------------------------------------------------
    // One more read through three wait states, to show the ruler stretches in
    // the right place: AS stays asserted for the extra clocks and everything
    // before S3 is unmoved.
    // ---------------------------------------------------------------------
    begin
      for (t = 0; t < 4096; t = t + 1) sw.mem[t] = 8'h70 + t[7:0];
      fork
        record();
        op_read(32'h3000_0100, 4, got, cycles);
      join
      check(got[31:0] === 32'h70717273, "read with three wait states: data");
      //                                     tick  0123456
      expect_pattern("waited read ECS", ecs_r, 7'b0111111);
      expect_pattern("waited read AS", as_r, 7'b1000000);  // still asserted
      expect_pattern("waited read DBEN", dben_r, 7'b1100000);
      expect_ge("waited read, AS width asserted",
                t_as_hi - t_as_lo, 100.0);
    end

    $display("bus_ruler_tb: %0d checks, %0d failures", checks, fails);
    if (fails == 0) $display("PASS: bus_ruler_tb");
    else            $display("FAIL: bus_ruler_tb");
    $finish;
  end

  initial begin
    #200_000;
    $display("FAIL: bus_ruler_tb timed out");
    $finish;
  end

endmodule
