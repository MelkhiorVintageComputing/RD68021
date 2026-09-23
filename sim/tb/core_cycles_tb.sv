// RD68021 -- instruction clock counts, for `make cycles`.
//
// tools/cycles.py writes the rows and judges the answers; this only measures.
// Each row is a program:
//
//          MOVEQ #1,D7 ; MOVEQ #1,D0 ; MOVEC D0,CACR     (cache on, two passes)
//   loop:  the prologue (tools/cycles.py lists it)
//          the row's setup words
//   X:     the instruction
//          four NOPs -- a landing pad for a branch that skips forward
//          DBRA D7,loop
//          BRA *
//
// and the count is from the instruction boundary at which X begins to the next
// one, on each pass: the first with the cache empty, the second with every word
// of the loop in it. That is how UM section 8 counts: an instruction's time is
// from the start of its execution to the start of the next one's.

`timescale 1ns / 1ps

module core_cycles_tb;

`undef  TB_ICACHE_ENTRIES
`define TB_ICACHE_ENTRIES 64
`include "rd68021_core_harness.svh"

  localparam logic [31:0] ISP0 = 32'h0000_1000;
  localparam logic [31:0] CODE = 32'h0000_0400;

  integer      vec;
  int unsigned nrows, r, i, npre, nins;
  logic [15:0] pre [0:15];
  logic [15:0] ins [0:7];
  string       tag, what;
  logic [31:0] at, x, loop_at, done_at;
  bit          reached;

  // Clocks, and the boundaries they fall on.
  longint unsigned clk_n;
  initial clk_n = 0;
  always @(posedge clk) clk_n++;

  longint unsigned t_start, t_start_end;
  int unsigned     pass;
  longint unsigned took [0:1];
  bit              armed, pending;
  bit              trace;
  initial trace = $test$plusargs("trace");

  // At a boundary the instruction that is finishing is still in stage D; the one
  // that begins is there one clock later. So a boundary is noted, and whether it
  // began X is read at the next falling edge.
  always @(negedge clk) begin
    if (rst_n) begin
      if (pending) begin
        pending = 1'b0;
        if (armed) begin
          // The boundary just noted ENDED the measured instruction.
          took[pass] = t_start_end - t_start;
          pass++;
          armed = 1'b0;
        end
        if (dut.u_ifu.pc_d === x && pass < 2) begin
          t_start = t_start_end;
          armed   = 1'b1;
        end
      end
      if (boundary) begin
        pending     = 1'b1;
        t_start_end = clk_n;
      end
      // +trace: every clock of the measured instruction's second pass.
      if (trace && armed && pass == 1)
        $display("  TRACE %0d upc=%0d retire=%b as=%b a=%08h fc=%0d rw=%b fetch_pend=%b cnt=%0d",
                 clk_n - t_start, dut.u_seq.upc, dut.u_seq.retire, as_n_o, a_o,
                 fc_o, rw_o, dut.u_ifu.fetch_pend_q, dut.u_ifu.cnt_q);
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

  initial begin
    rst_n = 1'b0;
    if (!$value$plusargs("vec=%s", what)) what = "build/cycles.vec";
    vec = $fopen(what, "r");
    if (vec == 0) begin
      $display("FAIL: core_cycles_tb cannot open %s", what);
      $finish;
    end
    void'($fscanf(vec, "%d", nrows));

    for (r = 0; r < nrows; r++) begin
      void'($fscanf(vec, "%s", tag));
      void'($fscanf(vec, "%h", npre));
      for (i = 0; i < npre; i++) void'($fscanf(vec, "%h", pre[i]));
      void'($fscanf(vec, "%h", nins));
      for (i = 0; i < nins; i++) void'($fscanf(vec, "%h", ins[i]));

      // Everything a row touches is below $4000: vectors, code at $400, the
      // stack under $1000, data at $2000-$2300 and the handlers at $3000.
      for (i = 0; i < 'h4000; i++) s32.mem[i] = 8'h00;
      poke_l(32'h0, ISP0);
      poke_l(32'h4, CODE);
      poke_l(32'h10, 32'h0000_3110);        // illegal instruction
      poke_l(32'h28, 32'h0000_3110);        // line A
      poke_l(32'h80, 32'h0000_3100);        // TRAP #0
      poke_w(32'h3000, 16'h4E75);           // RTS
      poke_w(32'h3100, 16'h4E73);           // RTE
      poke_w(32'h3110, 16'h54AF);           // ADDQ.L #2,(2,SP)
      poke_w(32'h3112, 16'h0002);
      poke_w(32'h3114, 16'h4E73);           // RTE

      // Where X lands is fixed by the prologue's length, which does not
      // depend on the row, and by the row's setup, which does.
      at = CODE;
      emit(16'h7E01);                       // MOVEQ #1,D7
      emit(16'h7001);                       // MOVEQ #1,D0
      emit(16'h4E7B); emit(16'h0002);       // MOVEC D0,CACR
      loop_at = at;
      x = loop_at + 32'd42 + 32'(npre * 2);
      emit(16'h7011);                       // MOVEQ #$11,D0
      emit(16'h7202);                       // MOVEQ #2,D1
      emit(16'h741F);                       // MOVEQ #$1F,D2
      emit(16'h7605);                       // MOVEQ #5,D3
      emit(16'h7800);                       // MOVEQ #0,D4
      emit(16'h7A00);                       // MOVEQ #0,D5
      emit(16'h307C); emit(16'h2000);       // MOVEA.W #$2000,A0
      emit(16'h327C); emit(16'h2100);       // MOVEA.W #$2100,A1
      emit(16'h347C); emit(16'h2200);       // MOVEA.W #$2200,A2
      emit(16'h367C); emit(16'h3000);       // MOVEA.W #$3000,A3
      emit(16'h2A7C); emit_l(x + 32'd2);    // MOVEA.L #X+2,A5
      emit(16'h2E7C); emit_l(ISP0);         // MOVEA.L #ISP0,A7
      emit(16'h7C01);                       // MOVEQ #1,D6
      if (at != loop_at + 32'd42) $display("FAIL: the prologue is not 42 bytes");
      for (i = 0; i < npre; i++) emit(pre[i]);
      if (at != x) $display("FAIL: X is not where it was meant to be");
      for (i = 0; i < nins; i++) emit(ins[i]);
      for (i = 0; i < 4; i++) emit(16'h4E71);
      emit(16'h51CF); emit(16'(loop_at - at));   // DBRA D7,loop
      done_at = at;
      emit(16'h60FE);                       // BRA *

      pass = 0; armed = 1'b0; pending = 1'b0;
      took[0] = 0; took[1] = 0;
      reset_dut();
      run_until(done_at, 20000, reached);
      if (!reached || pass != 2)
        $display("  FAIL: %s did not finish (%0d passes measured)", tag, pass);
      else
        $display("CYCLES %s %0d %0d", tag, took[1], took[0]);
    end
    $display("PASS: core_cycles_tb");
    $finish;
  end

endmodule
