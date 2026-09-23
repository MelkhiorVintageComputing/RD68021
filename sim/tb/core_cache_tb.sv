// RD68021 -- the instruction cache, UM section 4.
//
// The cache is architecturally invisible except in two ways, and this tests both:
// the bus (a hit makes no cycle), and code that modifies itself (a hit serves the
// long word as it was when it was cached, until something clears it -- which is
// exactly why CACR has a C bit). Everything else about it -- that programs give
// the same answers with it and without it -- is `make cache`.
//
// One program, parameterised. It calls one subroutine three times, setting CACR
// before each call to a value the test chooses, and the testbench counts the bus
// cycles that fetch the subroutine's long words during each call. The subroutine
// is a nine-times loop, so a call that misses fetches its first long word at
// least once and one that is served by the cache fetches it not at all.
//
//        prologue: USP, CAAR, D3 = D5 = 0
//        CACR <- v1 ; D1 <- 9 ; D5 <- 1 ; BSR SUB
//        CACR <- v2 ; D1 <- 9 ; D5 <- 2 ; BSR SUB
//        CACR <- v3 ; D1 <- 9 ; D5 <- 3 ; BSR SUB      (or drop to user first)
//        BRA *
//   SUB: ADDQ.L #1,D3 ; SUBQ.L #1,D1 ; BNE SUB ; RTS
//
// D5 is the call number, and the counters are indexed by it.

`timescale 1ns / 1ps

module core_cache_tb;

`undef  TB_ICACHE_ENTRIES
`define TB_ICACHE_ENTRIES 64
`include "rd68021_core_harness.svh"

  localparam logic [31:0] ISP0 = 32'h0000_1000;
  localparam logic [31:0] USP0 = 32'h0000_1800;
  localparam logic [31:0] CODE = 32'h0000_0400;
  localparam logic [31:0] SUB  = 32'h0000_0480;

  bit          reached;
  logic [31:0] at;
  logic [31:0] done_at;

  // Program-space bus cycles, per call, at each of the subroutine's two long
  // words and the one after it (which the pipe prefetches past the RTS and never
  // uses).
  int unsigned f0 [0:3];
  int unsigned f4 [0:3];
  int unsigned f8 [0:3];

  always @(negedge as_n_o) begin
    if (as_oe && fc_o[1:0] == 2'b10 && fc_o != 3'b111) begin
      if (a_o == SUB)            f0[dut.u_seq.dreg[5][1:0]]++;
      if (a_o == SUB + 32'h4)    f4[dut.u_seq.dreg[5][1:0]]++;
      if (a_o == SUB + 32'h8)    f8[dut.u_seq.dreg[5][1:0]]++;
    end
  end

  task automatic emit(input logic [15:0] w);
    poke_w(at, w);
    at = at + 2;
  endtask

  task automatic emit_l(input logic [31:0] v);
    emit(v[31:16]);
    emit(v[15:0]);
  endtask

  // One call: CACR <- v, D1 <- 9, D5 <- n, BSR.W SUB. `user` drops to the user
  // level first, where MOVEC is privileged, so the CACR write is left out.
  task automatic emit_call(input logic [31:0] v, input bit user);
    if (user) begin
      emit(16'h46FC); emit(16'h0000);          // MOVE #$0000,SR
    end else begin
      emit(16'h203C); emit_l(v);               // MOVE.L #v,D0
      emit(16'h4E7B); emit(16'h0002);          // MOVEC D0,CACR
    end
    emit(16'h7209);                            // MOVEQ #9,D1
    emit(16'h5285);                            // ADDQ.L #1,D5
    emit(16'h6100); emit(16'(SUB - (at)));     // BSR.W SUB
  endtask

  task automatic build(input logic [31:0] v1, input logic [31:0] v2,
                       input logic [31:0] v3, input bit user3,
                       input logic [31:0] caar_v);
    for (int i = 0; i < 4; i++) begin f0[i] = 0; f4[i] = 0; f8[i] = 0; end
    poke_l(32'h0, ISP0);
    poke_l(32'h4, CODE);
    at = CODE;
    emit(16'h207C); emit_l(USP0);              // MOVEA.L #USP0,A0
    emit(16'h4E60);                            // MOVE A0,USP
    emit(16'h243C); emit_l(caar_v);            // MOVE.L #caar,D2
    emit(16'h4E7B); emit(16'h2802);            // MOVEC D2,CAAR
    emit(16'h7600);                            // MOVEQ #0,D3
    emit(16'h7A00);                            // MOVEQ #0,D5
    emit_call(v1, 1'b0);
    emit_call(v2, 1'b0);
    emit_call(v3, user3);
    done_at = at;
    emit(16'h60FE);                            // BRA *
    if (at > SUB) $display("  FAIL: the program runs into SUB");
    at = SUB;
    emit(16'h5283);                            // ADDQ.L #1,D3
    emit(16'h5381);                            // SUBQ.L #1,D1
    emit(16'h66FA);                            // BNE.S SUB
    emit(16'h4E75);                            // RTS
    emit(16'h4E71); emit(16'h4E71);            // never executed
    emit(16'h4E71); emit(16'h4E71);
  endtask

  task automatic go(input string name);
    reset_dut();
    run_until(done_at, 20000, reached);
    check(reached, {name, ": the program finishes"});
  endtask

  initial begin
    rst_n = 1'b0;
    for (int i = 0; i < 65536; i++) s32.mem[i] = 8'h00;

    // ----------------------------------------------------------------------
    // Enabled throughout. The first call fills, the other two hit, and a hit
    // is no bus cycle at all -- UM 4.1, "the cycle ends".
    // ----------------------------------------------------------------------
    build(32'h1, 32'h1, 32'h1, 1'b0, 32'h0);
    go("enabled");
    check(f0[1] > 0, "enabled: the first call fetches the subroutine");
    check(f0[2] == 0 && f4[2] == 0, "enabled: the second call is served by the cache");
    check(f0[3] == 0 && f4[3] == 0, "enabled: ... and so is the third");
    check(f8[2] == 0, "enabled: the prefetch past the RTS was cached too");
    check(dut.u_seq.dreg[3] == 32'd27, "enabled: the subroutine ran 27 times");

    // UM 4.2: reset clears the cache. The RAM still holds the subroutine from
    // the run above; the valid bits say it does not.
    go("after reset");
    check(f0[1] > 0, "after reset: the first call misses again");

    // ----------------------------------------------------------------------
    // Disabled throughout: every iteration fetches.
    // ----------------------------------------------------------------------
    build(32'h0, 32'h0, 32'h0, 1'b0, 32'h0);
    go("disabled");
    check(f0[2] >= 9 && f0[3] >= 9, "disabled: every iteration is a bus cycle");

    // UM 4.3.1, F: "when the F-bit is set and a cache miss occurs, the entry is
    // not replaced". Frozen from the start, nothing ever gets in.
    build(32'h3, 32'h3, 32'h3, 1'b0, 32'h0);
    go("frozen empty");
    check(f0[2] >= 9, "frozen from the start: nothing is ever cached");

    // ... frozen after a fill: what is in there still hits.
    build(32'h1, 32'h3, 32'h3, 1'b0, 32'h0);
    go("frozen full");
    check(f0[2] == 0 && f4[2] == 0, "frozen after a fill: the entries still hit");

    // UM 4.3.1, E: "disabling the instruction cache does not flush the entries.
    // If the cache is reenabled, the previously valid entries remain valid."
    build(32'h1, 32'h0, 32'h1, 1'b0, 32'h0);
    go("re-enabled");
    check(f0[2] >= 9, "disabled after a fill: no hits");
    check(f0[3] == 0 && f4[3] == 0, "re-enabled: the old entries hit again");

    // C: clear all. The second call misses once per long word and then hits, and
    // C reads back as zero.
    build(32'h1, 32'h9, 32'h9, 1'b0, 32'h0);
    go("clear all");
    check(f0[2] >= 1 && f0[2] <= 2, "C: the second call misses, then hits");
    check(f4[2] >= 1 && f4[2] <= 2, "C: ... at both long words");
    check(dut.u_seq.cacr_q == 32'h1, "C: CACR reads back without it");

    // CE: clear the entry CAAR names, and only that one.
    build(32'h1, 32'h5, 32'h1, 1'b0, SUB);
    go("clear entry");
    check(f0[2] >= 1, "CE: the entry CAAR names misses");
    check(f4[2] == 0, "CE: the entry beside it does not");
    check(dut.u_seq.cacr_q == 32'h1, "CE: CACR reads back without it");

    // CE names an ENTRY, by index: the tag is not compared. $10480 has the same
    // index as SUB and a different tag, and clears it all the same.
    build(32'h1, 32'h5, 32'h1, 1'b0, SUB + 32'h0001_0000);
    go("clear entry by index");
    check(f0[2] >= 1, "CE: CAAR's index is all that counts");

    // UM 4.3: "the assertion of CDIS disables the cache, regardless of the state
    // of the E-bit", and -- like E -- it does not flush.
    build(32'h1, 32'h1, 32'h1, 1'b0, 32'h0);
    fork
      go("CDIS");
      begin
        wait (dut.u_seq.dreg[5] == 32'd2);
        cdis_n_i = 1'b0;
        wait (dut.u_seq.dreg[5] == 32'd3);
        cdis_n_i = 1'b1;
      end
    join
    check(f0[2] >= 9, "CDIS: the cache is off while it is asserted");
    check(f0[3] == 0 && f4[3] == 0, "CDIS: ... and its entries are still there after");

    // UM 4.1: the tag is A31-A8 AND FC2. The same code run at the user level is
    // a different address space and misses.
    build(32'h1, 32'h1, 32'h0, 1'b1, 32'h0);
    go("user level");
    check(f0[2] == 0, "FC2: the supervisor's second call hits");
    check(f0[3] > 0, "FC2: the user's call does not hit on the supervisor's entries");

    // A prefetch that ends in a bus error is not cached. The long word past the
    // RTS is prefetched and never used, so its bus error is never taken
    // (UM 5.5.1) -- but it must not come back later as a hit.
    build(32'h1, 32'h1, 32'h1, 1'b0, 32'h0);
    berr_base = SUB + 32'h8;
    berr_mask = 32'hFFFF_FFFC;
    berr_en   = 1'b1;
    go("faulted prefetch");
    berr_en   = 1'b0;
    check(f8[1] > 0, "faulted prefetch: the long word past the RTS is fetched");
    check(f8[2] > 0, "faulted prefetch: ... and fetched again, never cached");
    check(f0[2] == 0, "faulted prefetch: the rest of the subroutine still hits");

    // ----------------------------------------------------------------------
    // Code that modifies itself. After the first call the subroutine's first
    // instruction becomes ADDQ.L #2,D3. A cached copy keeps running the old one
    // until CACR's C bit clears it -- which is the whole reason the bit exists.
    // ----------------------------------------------------------------------
    build(32'h1, 32'h1, 32'h1, 1'b0, 32'h0);
    fork
      go("modified, cached");
      begin
        wait (dut.u_seq.dreg[5] == 32'd2);
        poke_w(SUB, 16'h5483);
      end
    join
    check(dut.u_seq.dreg[3] == 32'd27, "modified code: the cache serves the old word");

    build(32'h0, 32'h0, 32'h0, 1'b0, 32'h0);
    fork
      go("modified, uncached");
      begin
        wait (dut.u_seq.dreg[5] == 32'd2);
        poke_w(SUB, 16'h5483);
      end
    join
    check(dut.u_seq.dreg[3] == 32'd45, "modified code, no cache: the new word runs");

    build(32'h1, 32'h9, 32'h1, 1'b0, 32'h0);
    fork
      go("modified, cleared");
      begin
        wait (dut.u_seq.dreg[5] == 32'd2);
        poke_w(SUB, 16'h5483);
      end
    join
    check(dut.u_seq.dreg[3] == 32'd45, "modified code, C set: the new word runs");

    // And the pipe stayed sequential at every boundary through all of it.
    check(pipe_fails == 0, "the pipe invariant held throughout");

    $display("core_cache_tb: %0d checks, %0d failed", checks, fails);
    if (fails == 0) $display("PASS: core_cache_tb");
    else            $display("FAIL: core_cache_tb");
    $finish;
  end

endmodule
