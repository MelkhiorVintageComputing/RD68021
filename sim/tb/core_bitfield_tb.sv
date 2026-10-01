// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68021

// RD68021 -- the bit-field instructions in MEMORY, against a model of the
// manual rather than against an oracle.
//
// PRM 4's NOTE says a bit-field instruction "accesses only those bytes in
// memory that contain some portion of the bit field", and Musashi always reads
// and writes a long word, so the generated sweep cannot compare the two -- see
// doc/divergences.md. The sweep runs the register-direct forms, where there are
// no accesses to disagree about and the field arithmetic is the same; what the
// memory forms add is the base address, the byte count and the write-back, and
// that is what is here.
//
// The expectation is computed ONE BIT AT A TIME off the manual's definition:
// offset 0 is the most significant bit of the byte at the effective address,
// and increasing offset moves toward less significant bits and on into the
// bytes that follow. sim/tb/bitfield_tb.sv checks the unit the same way; this
// checks the instruction.

`timescale 1ns / 1ps

module core_bitfield_tb;

`include "rd68021_core_harness.svh"

  localparam logic [31:0] ISP0 = 32'h0000_1000;
  localparam logic [31:0] CODE = 32'h0000_0400;
  localparam logic [31:0] DATA = 32'h0000_2000;
  localparam int unsigned NIMG = 12;

  logic  [7:0] img [0:NIMG-1];
  bit          reached;
  int unsigned ci, oi, wi;
  int unsigned off, wid;
  logic [31:0] want, got;
  logic [31:0] insval;
  bit          want_n, want_z;
  int unsigned want_ffo;
  int unsigned k, b;
  logic  [7:0] want_img [0:NIMG-1];
  string       what;

  // A bit of the image, by the manual's numbering: bit `k` counted from the
  // most significant bit of img[0]. It reads the module's own array, because
  // iverilog will not take an unpacked one as an argument.
  function automatic bit mbit(input int unsigned k);
    mbit = img[k / 8][7 - (k % 8)];
  endfunction

  task automatic load_img();
    int unsigned i;
    for (i = 0; i < NIMG; i = i + 2)
      poke_w(DATA + i, {img[i], img[i+1]});
  endtask

  task automatic setup();
    int unsigned v;
    for (v = 0; v < 256; v = v + 1) poke_l(v * 4, 32'h0000_9000);
    poke_w(32'h0000_9000, 16'h60FE);
    poke_l(32'h0000_0000, ISP0);
    poke_l(32'h0000_0004, CODE);
    load_img();
  endtask

  initial begin
    $display("core_bitfield_tb: bit fields in memory, against the manual");

    for (ci = 0; ci < 8; ci = ci + 1)
    for (oi = 0; oi < 6; oi = oi + 1)
    for (wi = 0; wi < 6; wi = wi + 1) begin
      case (oi)
        0: off = 0;  1: off = 3;  2: off = 5;
        3: off = 7;  4: off = 8;  default: off = 17;
      endcase
      case (wi)
        0: wid = 1;  1: wid = 7;  2: wid = 8;
        3: wid = 9;  4: wid = 25; default: wid = 32;
      endcase

      // A memory image that is not symmetric in any direction, so that a
      // field taken from the wrong place cannot match by accident.
      for (k = 0; k < NIMG; k = k + 1)
        img[k] = 8'(8'h5A + 8'(k) * 8'h27);

      insval = 32'hA5C3_96F0;

      // The field, most significant bit first, straight off the definition.
      want     = 32'd0;
      want_z   = 1'b1;
      want_ffo = wid;
      for (k = 0; k < wid; k = k + 1) begin
        want = {want[30:0], mbit(off + k)};
        if (mbit(off + k)) begin
          want_z = 1'b0;
          if (want_ffo == wid) want_ffo = k;
        end
      end
      want_n = mbit(off);

      // What memory looks like afterwards, for the four that write.
      for (k = 0; k < NIMG; k = k + 1) want_img[k] = img[k];
      for (k = 0; k < wid; k = k + 1) begin
        b = off + k;
        case (ci)
          2: want_img[b/8][7 - (b%8)] = ~mbit(b);           // BFCHG
          4: want_img[b/8][7 - (b%8)] = 1'b0;                    // BFCLR
          6: want_img[b/8][7 - (b%8)] = 1'b1;                    // BFSET
          7: want_img[b/8][7 - (b%8)] = insval[wid - 1 - k];     // BFINS
          default: ;
        endcase
      end

      setup();
      // MOVEA.L #DATA,A0 ; MOVE.L #insval,D3 ; BFxxx (A0){off:wid} ; BRA *
      poke_w(CODE + 0, 16'h207C);
      poke_l(CODE + 2, DATA);
      poke_w(CODE + 6, 16'h263C);          // MOVE.L #insval,D3
      poke_l(CODE + 8, insval);
      poke_w(CODE + 12, 16'hE8D0 | 16'(ci << 8));
      poke_w(CODE + 14, 16'h3000 | 16'(off << 6) | 16'(wid % 32));
      poke_w(CODE + 16, 16'h60FE);
      reset_dut();
      run_until(CODE + 16, 3000, reached);

      what = $sformatf("%0d off=%0d wid=%0d", ci, off, wid);
      check(reached, {what, ": the program finishes"});

      // PRM 4: N is the field's most significant bit and Z is all of them
      // being clear -- except BFINS, whose page takes them from the value it
      // inserted.
      if (ci == 7) begin
        check(dut.u_seq.sr_q[3] === insval[wid - 1], {what, ": N from the insert"});
        check(dut.u_seq.sr_q[2] ===
              ((insval & ~(32'hFFFF_FFFF << wid)) == 32'd0),
              {what, ": Z from the insert"});
      end else begin
        check(dut.u_seq.sr_q[3] === want_n, {what, ": N"});
        check(dut.u_seq.sr_q[2] === want_z, {what, ": Z"});
      end
      check(dut.u_seq.sr_q[1] === 1'b0, {what, ": V is cleared"});
      check(dut.u_seq.sr_q[0] === 1'b0, {what, ": C is cleared"});

      case (ci)
        1: check(dut.u_seq.dreg[3] === want, {what, ": BFEXTU"});
        3: begin
          got = want;
          if (want[wid - 1]) got = want | (32'hFFFF_FFFF << wid);
          check(dut.u_seq.dreg[3] === got, {what, ": BFEXTS"});
        end
        5: check(dut.u_seq.dreg[3] === 32'(off + want_ffo), {what, ": BFFFO"});
        default: ;
      endcase

      if (ci == 2 || ci == 4 || ci == 6 || ci == 7) begin
        for (k = 0; k < NIMG; k = k + 2)
          check(peek_w(DATA + k) === {want_img[k], want_img[k+1]},
                $sformatf("%s: memory at +%0d", what, k));
      end
    end

    if (pipe_fails != 0)
      $display("  FAIL: the pipe invariant broke %0d times", pipe_fails);
    $display("core_bitfield_tb: %0d checks, %0d failed", checks, fails);
    if (fails == 0 && pipe_fails == 0) $display("PASS: core_bitfield_tb");
    else                               $display("FAIL: core_bitfield_tb");
    $finish;
  end

endmodule
