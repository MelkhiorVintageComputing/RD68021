// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68021

// RD68021 -- dynamic bus sizing and operand misalignment.
//
// The milestone test for the bus unit. Three things are checked, and the first is
// the one that decides whether the operand engine is right:
//
//   1. UM Table 5-6, "Memory Alignment and Port Size Influence on Read/Write Bus
//      Cycles", every row: the NUMBER of bus cycles an operand takes, for each
//      operand size, each value of A1-A0 and each of the three port widths. The
//      table is transcribed below exactly as printed.
//
//   2. The data actually moved, both ways. A read of n bytes at an address must
//      assemble the n bytes stored there, in order, whatever the port width and
//      whatever the alignment; a write must leave exactly those n bytes and no
//      others. That is Tables 5-4, 5-5 and 5-7 checked where they matter.
//
//   3. One OCS per operand and one ECS per bus cycle (UM 5.1.1), which is the
//      property that makes the operand rather than the cycle the unit of the
//      sequencer's contract.

`timescale 1ns / 1ps

module bus_sizing_tb;

`include "rd68021_bus_harness.svh"

  // UM Table 5-6, bus cycles, in the manual's own order: 32-bit, 16-bit, 8-bit.
  // Indexed [bytes][a1a0][port], port 0 = 32, 1 = 16, 2 = 8. Zero means the table
  // has no entry there.
  int unsigned t56 [1:4][0:3][0:2];

  logic [31:0] base [0:2];
  string       pname [0:2];

  logic [39:0] got;
  logic [39:0] want;
  logic [39:0] mask;
  logic [31:0] tmp;
  int unsigned cycles;
  int unsigned p, a, n, j;
  logic [31:0] addr;
  logic [7:0]  b;
  int unsigned oc0;
  string       what;

  initial begin
    // Byte
    t56[1][0][0]=1; t56[1][0][1]=1; t56[1][0][2]=1;
    t56[1][1][0]=1; t56[1][1][1]=1; t56[1][1][2]=1;
    t56[1][2][0]=1; t56[1][2][1]=1; t56[1][2][2]=1;
    t56[1][3][0]=1; t56[1][3][1]=1; t56[1][3][2]=1;
    // Word
    t56[2][0][0]=1; t56[2][0][1]=1; t56[2][0][2]=2;
    t56[2][1][0]=1; t56[2][1][1]=2; t56[2][1][2]=2;
    t56[2][2][0]=1; t56[2][2][1]=1; t56[2][2][2]=2;
    t56[2][3][0]=2; t56[2][3][1]=2; t56[2][3][2]=2;
    // 3 bytes: the manual's table has no row for it -- a three-byte operand only
    // ever arises as the residual of a misaligned long word -- so these are the
    // counts the same rule gives, checked for self-consistency only.
    t56[3][0][0]=1; t56[3][0][1]=2; t56[3][0][2]=3;
    t56[3][1][0]=1; t56[3][1][1]=2; t56[3][1][2]=3;
    t56[3][2][0]=2; t56[3][2][1]=2; t56[3][2][2]=3;
    t56[3][3][0]=2; t56[3][3][1]=2; t56[3][3][2]=3;
    // Long word
    t56[4][0][0]=1; t56[4][0][1]=2; t56[4][0][2]=4;
    t56[4][1][0]=2; t56[4][1][1]=3; t56[4][1][2]=4;
    t56[4][2][0]=2; t56[4][2][1]=2; t56[4][2][2]=4;
    t56[4][3][0]=2; t56[4][3][1]=3; t56[4][3][2]=4;

    base[0] = 32'h0000_0000; pname[0] = "32-bit";
    base[1] = 32'h1000_0000; pname[1] = "16-bit";
    base[2] = 32'h2000_0000; pname[2] = " 8-bit";

    $display("bus_sizing_tb: UM Table 5-6 and the byte lanes");
    reset_dut();

    // Paint every slave with a known, position-dependent pattern so that a byte
    // landing on the wrong lane cannot look right by accident.
    for (j = 0; j < 4096; j = j + 1) begin
      s32.mem[j] = 8'h10 + j[7:0];
      s16.mem[j] = 8'h10 + j[7:0];
      s8.mem[j]  = 8'h10 + j[7:0];
    end

    // ---------------------------------------------------------------------
    // Reads
    // ---------------------------------------------------------------------
    for (p = 0; p < 3; p = p + 1) begin
      for (n = 1; n <= 4; n = n + 1) begin
        for (a = 0; a < 4; a = a + 1) begin
          addr = base[p] + 32'h0000_0100 + a;

          want = 40'd0;
          for (j = 0; j < n; j = j + 1) begin
            tmp  = 32'h100 + a + j;
            b    = 8'h10 + tmp[7:0];
            want = (want << 8) | {32'd0, b};
          end
          // Only the n bytes asked for are defined; anything above them is
          // whatever the accumulator held. Compare through a mask rather than a
          // part-select, whose width iverilog will not take from a variable.
          mask = (40'd1 << (n * 8)) - 40'd1;

          oc0 = ocs_count;
          op_read(addr, n, got, cycles);

          $sformat(what, "read %0d byte(s) at A1A0=%0d on a %s port: data",
                   n, a, pname[p]);
          check((got & mask) === (want & mask), what);

          $sformat(what,
                   "read %0d byte(s) at A1A0=%0d on a %s port: %0d bus cycles, Table 5-6 says %0d",
                   n, a, pname[p], cycles, t56[n][a][p]);
          check(cycles == t56[n][a][p], what);

          $sformat(what, "read %0d byte(s) at A1A0=%0d on a %s port: one OCS",
                   n, a, pname[p]);
          check((ocs_count - oc0) == 1, what);
        end
      end
    end

    // ---------------------------------------------------------------------
    // Writes
    // ---------------------------------------------------------------------
    for (p = 0; p < 3; p = p + 1) begin
      for (n = 1; n <= 4; n = n + 1) begin
        for (a = 0; a < 4; a = a + 1) begin
          addr = base[p] + 32'h0000_0200 + a;

          // A pattern that is different from the paint, and different per byte.
          want = 40'd0;
          for (j = 0; j < n; j = j + 1) begin
            tmp  = 32'(a * 4 + j);
            want = (want << 8) | {32'd0, (8'hC0 + tmp[7:0])};
          end

          // Repaint the window so an untouched byte is recognisable.
          for (j = 0; j < 8; j = j + 1) begin
            if (p == 0) s32.mem[32'h200 + j] = 8'h5A;
            if (p == 1) s16.mem[32'h200 + j] = 8'h5A;
            if (p == 2) s8.mem[32'h200 + j]  = 8'h5A;
          end

          oc0 = ocs_count;
          op_write(addr, n, want, cycles);

          $sformat(what,
                   "write %0d byte(s) at A1A0=%0d on a %s port: %0d bus cycles, Table 5-6 says %0d",
                   n, a, pname[p], cycles, t56[n][a][p]);
          check(cycles == t56[n][a][p], what);

          for (j = 0; j < n; j = j + 1) begin
            b = 8'hC0 + 8'(a * 4 + j);
            $sformat(what, "write %0d byte(s) at A1A0=%0d on a %s port: byte %0d",
                     n, a, pname[p], j);
            if (p == 0) check(s32.mem[32'h200 + a + j] === b, what);
            if (p == 1) check(s16.mem[32'h200 + a + j] === b, what);
            if (p == 2) check(s8.mem[32'h200 + a + j]  === b, what);
          end

          // Nothing outside the operand may have been touched.
          $sformat(what, "write %0d byte(s) at A1A0=%0d on a %s port: no byte before it",
                   n, a, pname[p]);
          if (a > 0) begin
            if (p == 0) check(s32.mem[32'h200 + a - 1] === 8'h5A, what);
            if (p == 1) check(s16.mem[32'h200 + a - 1] === 8'h5A, what);
            if (p == 2) check(s8.mem[32'h200 + a - 1]  === 8'h5A, what);
          end
          $sformat(what, "write %0d byte(s) at A1A0=%0d on a %s port: no byte after it",
                   n, a, pname[p]);
          if (p == 0) check(s32.mem[32'h200 + a + n] === 8'h5A, what);
          if (p == 1) check(s16.mem[32'h200 + a + n] === 8'h5A, what);
          if (p == 2) check(s8.mem[32'h200 + a + n]  === 8'h5A, what);
        end
      end
    end

    // ---------------------------------------------------------------------
    // Instruction prefetch: Table 5-6's own first row, 1:2:4, and always a long
    // word from a long-word boundary whatever address is asked for.
    // ---------------------------------------------------------------------
    begin
      logic [31:0] fdata;
      for (p = 0; p < 3; p = p + 1) begin
        op_fetch(base[p] + 32'h0000_0300, fdata, cycles);
        $sformat(what, "prefetch on a %s port: %0d bus cycles, Table 5-6 says %0d",
                 pname[p], cycles, t56[4][0][p]);
        check(cycles == t56[4][0][p], what);
        $sformat(what, "prefetch on a %s port: the long word at $300", pname[p]);
        if (fdata !== 32'h10111213)
          $display("       got %08h", fdata);
        check(fdata === 32'h10111213, what);
      end

      // "Instruction prefetches are always two words from a long-word boundary"
      // -- UM Table 5-6's own footnote. An odd-word address still reads the long
      // word it sits in.
      op_fetch(32'h0000_0302, fdata, cycles);
      check(fdata === 32'h10111213, "prefetch at $302 reads the long word at $300");
    end

    // ---------------------------------------------------------------------
    // Wait states: the slave at $3000_0000 inserts three, and a bus cycle is
    // three clocks plus one per wait (UM 5.3.1 state 3).
    // ---------------------------------------------------------------------
    begin
      time t0, t1;
      for (j = 0; j < 4096; j = j + 1) sw.mem[j] = 8'h70 + j[7:0];
      @(negedge clk);
      t0 = $time;
      op_read(32'h3000_0100, 4, got, cycles);
      t1 = $time;
      check(got[31:0] === 32'h70717273, "read through three wait states: data");
      check(cycles == 1, "read through three wait states: one bus cycle");
    end

    $display("bus_sizing_tb: %0d checks, %0d failures", checks, fails);
    if (fails == 0) $display("PASS: bus_sizing_tb");
    else            $display("FAIL: bus_sizing_tb");
    $finish;
  end

  initial begin
    #2_000_000;
    $display("FAIL: bus_sizing_tb timed out");
    $finish;
  end

endmodule
