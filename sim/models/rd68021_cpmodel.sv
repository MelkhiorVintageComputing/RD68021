// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68021

// RD68021 -- a scripted coprocessor, for the coprocessor interface: M13.
//
// The other side of UM section 7, written from the protocol and not from any
// real coprocessor: it answers CPU-space type $2 cycles for one CpID (UM figure
// 7-3), holds a queue of what each readable interface register will return, and
// logs every access the processor makes. A testbench scripts the conversation --
// "the response CIR will say this, then this" -- and checks the log: which
// registers were touched, in what order, with what data. That is enough to
// drive every one of the twenty-one primitives and every exception the manual
// describes, including the ones a real coprocessor would never ask for.
//
// It is a 32-bit port with no wait states -- or, with `port16` set, answers its
// sixteen-bit registers the way the MC68881 does: "with DSACK1 only, on D31-D16,
// regardless of the value of A1" (MC68881 UM 7.2), which is a sixteen-bit port
// as far as the processor can tell, and so exercises dynamic bus sizing on the
// interface registers. The register map is UM figure 7-5:
//
//   $00 response (read)     $02 control (write)
//   $04 save (read)         $06 restore (read and write)
//   $08 operation word (w)  $0A command (write)
//   $0E condition (write)   $10 operand (read and write)
//   $14 register select (r) $18 instruction address (r/w)
//   $1C operand address (read and write)
//
// Each readable register has a queue. A read returns the head and pops it at the
// end of the cycle; an empty queue returns the register's default -- for the
// response CIR a null primitive with CA clear and PF set, which releases any
// instruction, and for the restore CIR whatever was last written to it, which is
// how a coprocessor says a format word is valid.
//
// Not synthesisable, and not meant to be: it is a testbench model.

`timescale 1ns / 1ps

module rd68021_cpmodel #(
    parameter logic [2:0] CPID  = 3'd1,
    parameter int         DEPTH = 64,
    parameter int         LOGN  = 256
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [31:0] a_i,
    input  logic  [2:0] fc_i,
    input  logic  [1:0] siz_i,
    input  logic        as_n_i,
    input  logic        ds_n_i,
    input  logic        rw_i,
    input  logic [31:0] d_i,
    output logic [31:0] d_o,
    output logic        d_oe,
    output logic  [1:0] dsack_n_o
);

  // ---- The script ----------------------------------------------------------
  logic [15:0] resp_q  [0:DEPTH-1];
  logic [15:0] save_q  [0:DEPTH-1];
  logic [15:0] rest_q  [0:DEPTH-1];
  logic [31:0] opnd_q  [0:DEPTH-1];
  logic [15:0] rsel_q  [0:DEPTH-1];
  logic [31:0] iadr_q  [0:DEPTH-1];
  logic [31:0] oadr_q  [0:DEPTH-1];
  int unsigned resp_n, resp_i, save_n, save_i, rest_n, rest_i, opnd_n, opnd_i;
  int unsigned rsel_n, rsel_i, iadr_n, iadr_i, oadr_n, oadr_i;
  logic [15:0] resp_default;
  logic [15:0] save_default;
  logic [15:0] rest_last;       // the last value written to the restore CIR
  logic        port16;          // answer the word registers as a 16-bit port

  // ---- The log -------------------------------------------------------------
  logic        log_rw    [0:LOGN-1];   // 1 = the processor read
  logic  [4:0] log_off   [0:LOGN-1];
  logic  [2:0] log_bytes [0:LOGN-1];
  logic [31:0] log_data  [0:LOGN-1];   // right justified
  int unsigned log_n;

  task automatic clear();
    resp_n = 0; resp_i = 0; save_n = 0; save_i = 0; rest_n = 0; rest_i = 0;
    opnd_n = 0; opnd_i = 0; rsel_n = 0; rsel_i = 0; iadr_n = 0; iadr_i = 0;
    oadr_n = 0; oadr_i = 0; log_n = 0;
    resp_default = 16'h0802;     // null, CA = 0, PF = 1: "processing finished"
    save_default = 16'h0000;     // empty
    rest_last    = 16'h0000;
    port16       = 1'b0;
  endtask

  initial clear();

  task automatic push_resp(input logic [15:0] v); resp_q[resp_n] = v; resp_n++; endtask
  task automatic push_save(input logic [15:0] v); save_q[save_n] = v; save_n++; endtask
  task automatic push_rest(input logic [15:0] v); rest_q[rest_n] = v; rest_n++; endtask
  task automatic push_opnd(input logic [31:0] v); opnd_q[opnd_n] = v; opnd_n++; endtask
  task automatic push_rsel(input logic [15:0] v); rsel_q[rsel_n] = v; rsel_n++; endtask
  task automatic push_iadr(input logic [31:0] v); iadr_q[iadr_n] = v; iadr_n++; endtask
  task automatic push_oadr(input logic [31:0] v); oadr_q[oadr_n] = v; oadr_n++; endtask

  // ---- Decoding a cycle ----------------------------------------------------
  // UM figure 7-3: FC 111, A19-A16 = 0010, A15-A13 = the CpID, A4-A0 the
  // register, and every other address bit zero.
  logic selected;
  assign selected = !as_n_i && (fc_i == 3'b111) && (a_i[19:16] == 4'h2)
                 && (a_i[15:13] == CPID)
                 && (a_i[31:20] == 12'h000) && (a_i[12:5] == 8'h00);

  function automatic int unsigned nbytes(input logic [1:0] s);
    nbytes = (s == 2'b00) ? 4 : int'(s);
  endfunction

  // The long word the register at `off` lives in, as the bus shows it.
  function automatic logic [31:0] long_view(input logic [4:0] off);
    logic [15:0] r, sv, rs, rg;
    logic [31:0] op, ia, oa;
    r  = (resp_i < resp_n) ? resp_q[resp_i] : resp_default;
    sv = (save_i < save_n) ? save_q[save_i] : save_default;
    rs = (rest_i < rest_n) ? rest_q[rest_i] : rest_last;
    op = (opnd_i < opnd_n) ? opnd_q[opnd_i] : 32'h0000_0000;
    rg = (rsel_i < rsel_n) ? rsel_q[rsel_i] : 16'h0000;
    ia = (iadr_i < iadr_n) ? iadr_q[iadr_i] : 32'h0000_0000;
    oa = (oadr_i < oadr_n) ? oadr_q[oadr_i] : 32'h0000_0000;
    case (off[4:2])
      3'd0:    long_view = {r, 16'h0000};
      3'd1:    long_view = {sv, rs};
      3'd4:    long_view = op;
      3'd5:    long_view = {rg, 16'h0000};
      3'd6:    long_view = ia;
      3'd7:    long_view = oa;
      default: long_view = 32'h0000_0000;
    endcase
  endfunction

  // Re-evaluated on every clock edge, not as a continuous assignment of the
  // function: doc/coding-standard.md's rule -- a function that reads module state
  // is re-evaluated when its ARGUMENTS change, not when the state it reads does,
  // so a queue popping or the restore CIR being written behind an unchanged
  // address left the old value on the bus.
  // The word registers: everything but the operand CIR and the two address CIRs.
  logic word_reg;
  assign word_reg = (a_i[4:2] != 3'd4) && (a_i[4:2] != 3'd6) && (a_i[4:2] != 3'd7);

  always @(clk or a_i or port16) begin
    d_o = long_view(a_i[4:0]);
    // A sixteen-bit port puts the addressed word on D31-D16 whichever half of
    // the long word it is.
    if (port16 && word_reg && a_i[1]) d_o = {d_o[15:0], 16'h0000};
  end
  assign d_oe      = selected && rw_i;
  // UM table 5-1: DSACK1 alone is a sixteen-bit port, both a thirty-two-bit one.
  assign dsack_n_o = !selected ? 2'b11 : (port16 && word_reg) ? 2'b01 : 2'b00;

  // The bytes a write carried, right justified: a 32-bit port puts byte k of an
  // access at lane (A1A0 + k) -- UM table 5-7.
  function automatic logic [31:0] wr_value(input logic [31:0] d,
                                           input logic [1:0] a10,
                                           input int unsigned n);
    logic [31:0] v;
    int unsigned k;
    v = 32'd0;
    for (k = 0; k < n && (a10 + k) < 4; k++)
      v = (v << 8) | ((d >> (8 * (3 - (a10 + k)))) & 32'hFF);
    wr_value = v;
  endfunction

  // One cycle is logged once, at its end, which is when a read is popped: the
  // processor latches the data in S5, before AS negates.
  logic        in_cycle;
  logic        cur_rw;
  logic  [4:0] cur_off;
  logic  [2:0] cur_n;
  logic [31:0] cur_data;

  initial in_cycle = 1'b0;

  always @(posedge clk) begin
    if (selected) begin
      in_cycle <= 1'b1;
      cur_rw   <= rw_i;
      cur_off  <= a_i[4:0];
      cur_n    <= 3'(nbytes(siz_i));
      if (rw_i) cur_data <= wr_value(long_view(a_i[4:0]), a_i[1:0], nbytes(siz_i));
      else if (!ds_n_i)
        cur_data <= (port16 && word_reg) ? {16'h0000, d_i[31:16]}
                                         : wr_value(d_i, a_i[1:0], nbytes(siz_i));
    end else if (in_cycle) begin
      in_cycle <= 1'b0;
      if (log_n < LOGN) begin
        log_rw[log_n]    = cur_rw;
        log_off[log_n]   = cur_off;
        log_bytes[log_n] = cur_n;
        log_data[log_n]  = cur_data;
      end
      log_n = log_n + 1;
      if (cur_rw) begin
        case (cur_off)
          5'h00: if (resp_i < resp_n) resp_i = resp_i + 1;
          5'h04: if (save_i < save_n) save_i = save_i + 1;
          5'h06: if (rest_i < rest_n) rest_i = rest_i + 1;
          5'h14: if (rsel_i < rsel_n) rsel_i = rsel_i + 1;
          5'h18: if (iadr_i < iadr_n) iadr_i = iadr_i + 1;
          5'h1C: if (oadr_i < oadr_n) oadr_i = oadr_i + 1;
          default: if (cur_off[4:2] == 3'd4 && opnd_i < opnd_n) opnd_i = opnd_i + 1;
        endcase
      end else if (cur_off == 5'h06) begin
        rest_last = cur_data[15:0];
      end
    end
  end

  logic unused;
  assign unused = &{1'b1, rst_n};

endmodule
