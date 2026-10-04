// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68021

// RD68021 -- a real program, instruction by instruction, against Musashi.
//
// The per-opcode sweep (sim/tb/core_vec_tb.sv) runs one instruction at a time
// from a state nobody ever reached by executing anything. This runs a program:
// the instruction mix, the register allocation and the addressing modes are
// GCC's, so they are a mix nobody here designed, and every instruction starts
// from the state the one before it left.
//
// The comparison is at every instruction boundary, so a divergence is reported
// at the instruction that caused it and not at the end of a program that came
// out wrong.
//
// Musashi is an ORACLE, not a source. Where the two disagree the manual decides.

`timescale 1ns / 1ps

module core_cosim_tb;

`include "rd68021_core_harness.svh"

  integer      trc;
  int unsigned nstep;
  logic [31:0] tpc;
  logic [31:0] treg [0:17];       // d0..d7 a0..a6 usp isp sr
  logic [31:0] start_pc;

  int unsigned k, n;
  int unsigned shown;
  bit          ok, bad;
  string       image, trace, why;

  // The bus, cycle by cycle, for `make cache` to hold two builds of the core to
  // "the same program makes the same data cycles, and the cache only ever takes
  // instruction fetches away". One line per cycle at the negation of AS: the
  // requester (F for the instruction pipe, D for everything else), the function
  // code, the address, the size, the direction, and what a write wrote.
  integer bus_log;
  string  bus_file;
  initial bus_log = 0;

  always @(posedge as_n_o) if (bus_log != 0 && rst_n)
    $fdisplay(bus_log, "%s %0d %08h %0d %s %08h",
              dut.u_biu.op_isfetch ? "F" : "D", fc_o, a_o, siz_o,
              rw_o ? "R" : "W", rw_o ? 32'd0 : d_o);

  // Where the clocks go, for doc/timing-divergences.md: +stalls counts, from
  // reset to the end, the clocks a bus microword spends stalled, by direction,
  // and how many of each retired -- the ceiling for overlapping operand cycles
  // with the microcode around them.
  bit          stalls;
  longint unsigned st_clk, st_wr, st_rd, n_wr, n_rd, st_other, st_fetch;
  initial begin
    stalls = $test$plusargs("stalls");
    st_clk = 0; st_wr = 0; st_rd = 0; n_wr = 0; n_rd = 0; st_other = 0;
    st_fetch = 0;
  end
  always @(posedge clk) if (stalls && rst_n) begin
    st_clk = st_clk + 1;
    if (dut.u_seq.bus_req) begin
      if (!dut.u_seq.retire) begin
        if (dut.u_seq.other_stall)                     st_other = st_other + 1;
        else if (dut.u_seq.req_kind == rd68021_pkg::CT_WRITE) st_wr = st_wr + 1;
        else                                           st_rd = st_rd + 1;
        if (dut.u_biu.op_active && dut.u_biu.op_isfetch) st_fetch = st_fetch + 1;
      end else if (dut.u_seq.req_kind == rd68021_pkg::CT_WRITE) n_wr = n_wr + 1;
      else                                             n_rd = n_rd + 1;
    end
  end
  final if (stalls)
    $display("core_cosim_tb: stalls: %0d clocks; %0d writes stalled %0d clocks, %0d reads %0d, %0d waiting on other things, %0d of the bus stalls behind a prefetch",
             st_clk, n_wr, st_wr, n_rd, st_rd, st_other, st_fetch);

  initial begin
    if ($value$plusargs("buslog=%s", bus_file)) bus_log = $fopen(bus_file, "w");
    if (!$value$plusargs("image=%s", image)) image = "build/programs/arith.hex";
    if (!$value$plusargs("trace=%s", trace)) trace = "build/programs/arith.trc";

    // The image IS the memory: the vectors at zero, the program at $1000 and
    // the stack at the top of the first 64 KB.
    for (n = 0; n < 65536; n = n + 1) s32.mem[n] = 8'h00;
    $readmemh(image, s32.mem);

    trc = $fopen(trace, "r");
    if (trc == 0) begin
      $display("FAIL: core_cosim_tb cannot open %s", trace);
      $finish;
    end
    n = $fscanf(trc, "%h", nstep);
    $display("core_cosim_tb: %0d instructions to compare", nstep);

    // The first entry is the state before the first instruction, which is what
    // reset leaves behind. It is read to get the entry point and is NOT
    // compared: the data registers after a reset are not defined by anything,
    // so the two would be agreeing about nothing.
    void'($fscanf(trc, "%h", start_pc));
    for (n = 0; n < 18; n = n + 1) void'($fscanf(trc, "%h", treg[n]));

    shown = 0;
    bad   = 1'b0;

    reset_dut();
    run_until(start_pc, 400, ok);
    if (!ok) begin
      $display("  FAIL: the core never reached the entry point %08h", start_pc);
      bad = 1'b1;
    end

    for (k = 1; k < nstep && !bad; k = k + 1) begin
      void'($fscanf(trc, "%h", tpc));
      for (n = 0; n < 18; n = n + 1) void'($fscanf(trc, "%h", treg[n]));

      // A long division is thirty-two clocks and a MOVEM of sixteen registers
      // is more, so the limit is generous; what it is really there for is to
      // turn a hang into a failure.
      step_one(3000, ok);
      if (!ok) begin
        $display("  FAIL: instruction %0d never retired (the core is at %08h)",
                 k - 1, dut.u_ifu.pc_d);
        bad = 1'b1;
      end

      why = "";
      if (!bad && dut.u_ifu.pc_d !== tpc)
        $sformat(why, "the PC is %08h, Musashi says %08h", dut.u_ifu.pc_d, tpc);
      for (n = 0; n < 8; n = n + 1)
        if (!bad && why == "" && dut.u_seq.dreg[n] !== treg[n])
          $sformat(why, "D%0d is %08h, Musashi says %08h",
                   n, dut.u_seq.dreg[n], treg[n]);
      for (n = 0; n < 7; n = n + 1)
        if (!bad && why == "" && dut.u_seq.areg[n] !== treg[8 + n])
          $sformat(why, "A%0d is %08h, Musashi says %08h",
                   n, dut.u_seq.areg[n], treg[8 + n]);
      if (!bad && why == "" && dut.u_seq.isp_q !== treg[16])
        $sformat(why, "the stack pointer is %08h, Musashi says %08h",
                 dut.u_seq.isp_q, treg[16]);
      if (!bad && why == "" && dut.u_seq.sr_q !== treg[17][15:0])
        $sformat(why, "SR is %04h, Musashi says %04h",
                 dut.u_seq.sr_q, treg[17][15:0]);

      if (!bad && why != "") begin
        $display("  FAIL: after instruction %0d: %s", k - 1, why);
        bad = 1'b1;
      end
      if ((k % 2000) == 0) $display("  .. %0d of %0d", k, nstep);
    end

    $fclose(trc);
    if (!bad) begin
      $display("core_cosim_tb: %0d instructions, every register at every boundary",
               nstep - 1);
      $display("PASS: core_cosim_tb");
    end else begin
      $display("FAIL: core_cosim_tb");
    end
    $finish;
  end

  initial begin
    #8_000_000_000;
    $display("FAIL: core_cosim_tb timed out");
    $finish;
  end

endmodule
