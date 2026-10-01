// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68021

// RD68021 -- every addressing mode, against Musashi.
//
// There are two instruments. LEA <ea>,A0 -- PRM 4, "the effective address is
// loaded into the specified address register" -- computes an address and does
// nothing else with it, so the address itself is the answer and nothing can
// hide a wrong one. But LEA takes only the control modes, so (An)+, -(An) and
// the fetch an effective address exists to make are out of its reach; those are
// measured with MOVE.L <ea>,D0, and show up in the final register state and in
// the access list rather than in the address.
//
// tools/cosim/musashi_ea.c builds one test per (mode, extension-word shape),
// runs it through Musashi as an MC68020 and records the address it produced and
// every data access it made on the way. This replays each one through the core
// and compares both.
//
// Musashi is an ORACLE, not a source. Where the two disagree the manual decides;
// PRM section 2 is what both were written from, independently.

`timescale 1ns / 1ps

module core_ea_tb;

`include "rd68021_core_harness.svh"

  localparam logic [31:0] PROG_BASE = 32'h0000_1000;

  integer      vec;
  int unsigned ntests;
  int unsigned idx, nwords, nreads;
  logic [31:0] w   [0:5];
  logic [31:0] dv  [0:7];
  logic [31:0] av  [0:6];
  logic [31:0] want_ea;
  logic [31:0] radd [0:7];
  logic        rprog [0:7];
  logic [31:0] got_ea;
  logic [31:0] fd0;
  logic [31:0] fav [0:6];
  int unsigned bad_reg;

  int unsigned t, n;
  logic [31:0] n_space;
  int unsigned passed, failed, mismatch_shown;
  bit          reached;
  bit          acc_ok;
  string       what;

  initial begin
    if (!$value$plusargs("vec=%s", what)) what = "build/ea-vectors.hex";
    vec = $fopen(what, "r");
    if (vec == 0) begin
      $display("FAIL: core_ea_tb cannot open the vector file");
      $finish;
    end
    n = $fscanf(vec, "%h", ntests);
    $display("core_ea_tb: %0d effective-address vectors from Musashi", ntests);

    passed = 0;
    failed = 0;
    mismatch_shown = 0;

    // The oracle starts from a zeroed megabyte. An unwritten byte here would be
    // X, and a test whose address lands outside the block both sides fill would
    // then disagree for no reason but that.
    for (n = 0; n < 65536; n = n + 1) begin
      s32.mem[n] = 8'h00;
      s16.mem[n] = 8'h00;
      s8.mem[n]  = 8'h00;
    end

    for (t = 0; t < ntests; t = t + 1) begin
      n = $fscanf(vec, "%h %h %h %h %h %h %h %h",
                  idx, nwords, w[0], w[1], w[2], w[3], w[4], w[5]);
      for (n = 0; n < 8; n = n + 1) void'($fscanf(vec, "%h", dv[n]));
      for (n = 0; n < 7; n = n + 1) void'($fscanf(vec, "%h", av[n]));
      void'($fscanf(vec, "%h", want_ea));
      void'($fscanf(vec, "%h", nreads));
      for (n = 0; n < nreads; n = n + 1) begin
        void'($fscanf(vec, "%h", radd[n]));
        void'($fscanf(vec, "%h", n_space));
        rprog[n] = n_space[0];
      end
      // The registers the oracle finished with. For LEA this repeats what
      // want_ea already said; for MOVE.L it is the whole answer, because (An)+
      // and -(An) leave their mark nowhere else.
      void'($fscanf(vec, "%h", fd0));
      for (n = 0; n < 7; n = n + 1) void'($fscanf(vec, "%h", fav[n]));

      // ------------------------------------------------------------------
      // The vectors, the instruction, and a place to stop.
      // ------------------------------------------------------------------
      poke_l(32'h0000_0000, 32'h0000_8000);        // initial stack pointer
      poke_l(32'h0000_0004, PROG_BASE);            // initial program counter
      for (n = 0; n < 6; n = n + 1)
        poke_w(PROG_BASE + 32'(n * 2), w[n][15:0]);
      // A NOP, which is what the oracle writes there (tools/cosim/musashi_ea.c).
      // Memory-indirect modes read memory to build an address and nothing stops
      // one of them reading the word after the instruction, so the two memories
      // have to agree here as everywhere else. run_until stops the core at this
      // address, so it is never executed.
      poke_w(PROG_BASE + 32'(nwords * 2), 16'h4E71);

      // Something recognisable wherever a memory-indirect address might land,
      // laid out exactly as the oracle laid it out.
      for (n = 0; n < 1024; n = n + 4)
        poke_l(32'h0000_2000 + 32'(n), 32'h0000_3000 + 32'(n));

      reset_dut();
      // The reset sequence reads two vectors before it fetches anything, so
      // there is room to deposit the register state it is to start from.
      for (n = 0; n < 8; n = n + 1) dut.u_seq.dreg[n] = dv[n];
      for (n = 0; n < 7; n = n + 1) dut.u_seq.areg[n] = av[n];

      if (t < 2)
        $display("  .. vector %0d: w=%04h av0=%08h dep=%08h want=%08h",
                 idx, w[0][15:0], av[0], dut.u_seq.areg[0], want_ea);
      // Run up to the instruction first and only then start counting: reset
      // exception processing reads the two vectors from data space, and those
      // are not accesses the instruction made.
      run_until(PROG_BASE, 200, reached);
      nacc = 0;
      if (reached) run_until(PROG_BASE + 32'(nwords * 2), 200, reached);
      if (t < 2)
        $display("  .. after: areg0=%08h pc_d=%08h reached=%b",
                 dut.u_seq.areg[0], dut.u_ifu.pc_d, reached);
      got_ea = dut.u_seq.areg[0];

      if (!reached) begin
        failed = failed + 1;
        if (mismatch_shown < 12) begin
          mismatch_shown = mismatch_shown + 1;
          $display("  FAIL: vector %0d (%04h %04h %04h) never retired",
                   idx, w[0][15:0], w[1][15:0], w[2][15:0]);
        end
      end else if (got_ea !== want_ea) begin
        failed = failed + 1;
        if (mismatch_shown < 12) begin
          mismatch_shown = mismatch_shown + 1;
          $display("  FAIL: vector %0d (%04h %04h %04h): Musashi says %08h, this core says %08h",
                   idx, w[0][15:0], w[1][15:0], w[2][15:0], want_ea, got_ea);
        end
      end else if (nacc != nreads) begin
        failed = failed + 1;
        if (mismatch_shown < 12) begin
          mismatch_shown = mismatch_shown + 1;
          $display("  FAIL: vector %0d: Musashi made %0d data accesses, this core made %0d",
                   idx, nreads, nacc);
        end
      end else begin
        acc_ok = 1'b1;
        for (n = 0; n < nreads; n = n + 1)
          if (acc_addr[n] !== radd[n] || acc_prog[n] !== rprog[n]) acc_ok = 1'b0;
        if (!acc_ok) begin
          failed = failed + 1;
          if (mismatch_shown < 12) begin
            mismatch_shown = mismatch_shown + 1;
            $display("  FAIL: vector %0d: the access list differs -- Musashi read %08h in %s space, this core read %08h in %s space",
                     idx, radd[0], rprog[0] ? "program" : "data",
                     acc_addr[0], acc_prog[0] ? "program" : "data");
          end
        end else begin
          // The final register state. For LEA this only repeats what got_ea
          // already said; for MOVE.L it is the whole answer, because (An)+ and
          // -(An) leave their mark nowhere else.
          bad_reg = 8;
          if (dut.u_seq.dreg[0] !== fd0) bad_reg = 7;
          for (n = 0; n < 7; n = n + 1)
            if (dut.u_seq.areg[n] !== fav[n] && bad_reg == 8) bad_reg = n;
          if (bad_reg != 8) begin
            failed = failed + 1;
            if (mismatch_shown < 12) begin
              mismatch_shown = mismatch_shown + 1;
              if (bad_reg == 7)
                $display("  FAIL: vector %0d (%04h %04h): D0 is %08h, Musashi says %08h",
                         idx, w[0][15:0], w[1][15:0], dut.u_seq.dreg[0], fd0);
              else
                $display("  FAIL: vector %0d (%04h %04h): A%0d is %08h, Musashi says %08h",
                         idx, w[0][15:0], w[1][15:0], bad_reg,
                         dut.u_seq.areg[bad_reg], fav[bad_reg]);
            end
          end else begin
            passed = passed + 1;
          end
        end
      end
    end

    $fclose(vec);
    $display("core_ea_tb: %0d passed, %0d failed, of %0d", passed, failed, ntests);
    if (failed == 0) $display("PASS: core_ea_tb");
    else             $display("FAIL: core_ea_tb");
    $finish;
  end

  initial begin
    #200_000_000;
    $display("FAIL: core_ea_tb timed out");
    $finish;
  end

endmodule
