// RD68021 -- the coprocessor interface: M13.
//
// UM section 7 against a scripted coprocessor (sim/models/rd68021_cpmodel.sv).
// Every test states what the coprocessor will say -- the primitives it puts in
// the response CIR, the operands and registers it hands over -- runs a
// coprocessor instruction, and checks two things: what the processor did to
// its own state and memory, and the exact sequence of interface-register
// accesses it made, which is the protocol itself.
//
// Encodings, CpID 1:
//   cpGEN    $F200|ea, command      cpBcc.W/.L  $F280/$F2C0|cc
//   cpScc    $F240|ea, cc           cpDBcc      $F248|Dn, cc, disp
//   cpTRAPcc $F27A/B/C, cc          cpSAVE      $F300|ea   cpRESTORE $F340|ea

`timescale 1ns / 1ps

`ifndef TB_COPROCESSOR
`define TB_COPROCESSOR
`endif
module core_cpif_tb;

`include "rd68021_core_harness.svh"

  localparam logic [31:0] ISP0 = 32'h0000_1000;
  localparam logic [31:0] CODE = 32'h0000_0400;
  localparam logic [31:0] HAND = 32'h0000_0600;
  localparam logic [31:0] DATA = 32'h0000_2000;

  // The interface registers -- UM figure 7-5.
  localparam logic [4:0] R_RESP = 5'h00, R_CTRL = 5'h02, R_SAVE = 5'h04,
                         R_REST = 5'h06, R_OPW = 5'h08, R_CMD = 5'h0A,
                         R_COND = 5'h0E, R_OPND = 5'h10, R_RSEL = 5'h14,
                         R_IADR = 5'h18, R_OADR = 5'h1C;

  bit          reached;
  logic [31:0] base;
  int unsigned li;       // the next log entry a test expects

  // An autovectoring interrupt source that drops its request when acknowledged.
  int unsigned iacks;
  initial iacks = 0;
  wire iack_now = !as_n_o && (fc_o === 3'b111) && (a_o[19:16] === 4'hF);
  always @(*) avec_n_i = !iack_now;
  always @(posedge iack_now) begin
    iacks   = iacks + 1;
    ipl_n_i = 3'b111;
  end

  task automatic base_setup();
    int unsigned v;
    for (v = 0; v < 256; v = v + 1)
      poke_l(v * 4, 32'h0000_9000);
    poke_w(32'h0000_9000, 16'h60FE);       // an unexpected vector spins
    poke_l(32'h0000_0000, ISP0);
    poke_l(32'h0000_0004, CODE);
    cp.clear();
    berr_en = 1'b0;
    li = 0;
  endtask

  // One interface-register access, in order. `n` bytes, `v` right justified.
  task automatic expect_cir(input logic rw, input logic [4:0] off,
                            input int unsigned n, input logic [31:0] v,
                            input string what);
    string s;
    s = $sformatf("%s: CIR access %0d is %s $%02h, %0d bytes, $%08h", what, li,
                  rw ? "a read of" : "a write to", off, n, v);
    if (li >= cp.log_n) begin
      check(1'b0, {s, " -- there were only ", $sformatf("%0d", cp.log_n)});
    end else begin
      check(cp.log_rw[li] === rw && cp.log_off[li] === off
            && cp.log_bytes[li] === 3'(n) && cp.log_data[li] === v,
            {s, $sformatf(" (got %s $%02h, %0d, $%08h)",
                          cp.log_rw[li] ? "read" : "write", cp.log_off[li],
                          cp.log_bytes[li], cp.log_data[li])});
    end
    li = li + 1;
  endtask

  task automatic expect_end(input string what);
    check(cp.log_n == li, $sformatf("%s: %0d CIR accesses, expected %0d",
                                    what, cp.log_n, li));
  endtask

  initial begin
    $display("core_cpif_tb: the coprocessor interface");

    // ======================================================================
    // cpGEN, released at once -- UM 7.2.1.2. The command word goes to the
    // command CIR, the response CIR says "processing finished", and the next
    // instruction runs.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0, 16'hF200);            // cpGEN
    poke_w(CODE + 2, 16'h4800);            // the command word
    poke_w(CODE + 4, 16'h7001);            // MOVEQ #1,D0
    poke_w(CODE + 6, 16'h60FE);
    reset_dut();
    run_until(CODE + 6, 3000, reached);
    check(reached, "cpGEN: the next instruction runs");
    check(dut.u_seq.dreg[0] === 32'h0000_0001, "cpGEN: and only it");
    expect_cir(1'b0, R_CMD, 2, 32'h4800, "cpGEN");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "cpGEN");
    expect_end("cpGEN");

    // ======================================================================
    // Transfer single main processor register -- UM 7.4.13, both ways, and
    // come-again chaining them -- UM 7.4.2.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0, 16'hF200);
    poke_w(CODE + 2, 16'h1234);
    poke_w(CODE + 4, 16'h60FE);
    cp.push_resp(16'h8C03);                // CA, DR=0, D3 -> CP
    cp.push_resp(16'hAC0A);                // CA, DR=1, CP -> A2
    cp.push_resp(16'h0802);
    cp.push_opnd(32'hCAFE_F00D);
    reset_dut();
    dut.u_seq.dreg[3] = 32'h1122_3344;
    run_until(CODE + 4, 3000, reached);
    check(reached, "single register: the instruction ends");
    check(dut.u_seq.areg[2] === 32'hCAFE_F00D, "single register: A2 loaded");
    expect_cir(1'b0, R_CMD, 2, 32'h1234, "single register");
    expect_cir(1'b1, R_RESP, 2, 32'h8C03, "single register");
    expect_cir(1'b0, R_OPND, 4, 32'h1122_3344, "single register: D3 out");
    expect_cir(1'b1, R_RESP, 2, 32'hAC0A, "single register");
    expect_cir(1'b1, R_OPND, 4, 32'hCAFE_F00D, "single register: A2 in");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "single register");
    expect_end("single register");

    // ======================================================================
    // Evaluate effective address and transfer data -- UM 7.4.9. Twelve bytes
    // from (A0) to the coprocessor in three long words, then ten bytes from it
    // to -(A1): two long words and a word, the register stepped by ten first.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0, 16'hF210);            // cpGEN, <ea> = (A0)
    poke_w(CODE + 2, 16'h0001);
    poke_w(CODE + 4, 16'hF221);            // cpGEN, <ea> = -(A1)
    poke_w(CODE + 6, 16'h0002);
    poke_w(CODE + 8, 16'h60FE);
    poke_l(DATA + 0, 32'h0102_0304);
    poke_l(DATA + 4, 32'h0506_0708);
    poke_l(DATA + 8, 32'h090A_0B0C);
    cp.push_resp(16'h970C);                // CA, DR=0, any <ea>, 12 bytes
    cp.push_resp(16'h0802);
    cp.push_resp(16'hB70A);                // CA, DR=1, any <ea>, 10 bytes
    cp.push_resp(16'h0802);
    cp.push_opnd(32'hA1A2_A3A4);
    cp.push_opnd(32'hB1B2_B3B4);
    cp.push_opnd(32'hC1C2_0000);
    reset_dut();
    dut.u_seq.areg[0] = DATA;
    dut.u_seq.areg[1] = DATA + 32'h40;
    run_until(CODE + 8, 3000, reached);
    check(reached, "eval <ea> and transfer: both instructions end");
    expect_cir(1'b0, R_CMD, 2, 32'h0001, "to the coprocessor");
    expect_cir(1'b1, R_RESP, 2, 32'h970C, "to the coprocessor");
    expect_cir(1'b0, R_OPND, 4, 32'h0102_0304, "to the coprocessor: first");
    expect_cir(1'b0, R_OPND, 4, 32'h0506_0708, "to the coprocessor: second");
    expect_cir(1'b0, R_OPND, 4, 32'h090A_0B0C, "to the coprocessor: third");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "to the coprocessor");
    expect_cir(1'b0, R_CMD, 2, 32'h0002, "from the coprocessor");
    expect_cir(1'b1, R_RESP, 2, 32'hB70A, "from the coprocessor");
    expect_cir(1'b1, R_OPND, 4, 32'hA1A2_A3A4, "from the coprocessor: first");
    expect_cir(1'b1, R_OPND, 4, 32'hB1B2_B3B4, "from the coprocessor: second");
    // UM 7.3.8: the remainder "is aligned to the most significant byte".
    expect_cir(1'b1, R_OPND, 2, 32'h0000_C1C2, "from the coprocessor: the tail");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "from the coprocessor");
    expect_end("eval <ea> and transfer");
    check(dut.u_seq.areg[1] === DATA + 32'h36, "-(A1): stepped back by ten");
    check(peek_l(DATA + 32'h36) === 32'hA1A2_A3A4 &&
          peek_l(DATA + 32'h3A) === 32'hB1B2_B3B4 &&
          peek_w(DATA + 32'h3E) === 16'hC1C2,
          "-(A1): the ten bytes, ascending from the new address");

    // ======================================================================
    // Take preinstruction exception -- UM 7.4.18: the exception acknowledge,
    // then a four-word frame whose program counter is the operation word, so
    // that RTE starts the instruction again.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0100, HAND);           // vector 64
    poke_w(CODE + 0, 16'hF200);
    poke_w(CODE + 2, 16'h5555);
    poke_w(CODE + 4, 16'h60FE);
    poke_w(HAND + 0, 16'h60FE);
    cp.push_resp(16'h1C40);                // take preinstruction, vector 64
    reset_dut();
    run_until(HAND, 3000, reached);
    check(reached, "preinstruction: the handler for vector 64 runs");
    base = ISP0 - 32'h8;
    check(dut.u_seq.isp_q === base, "preinstruction: a four-word frame");
    check(peek_l(base + 2) === CODE, "preinstruction: +$02 the operation word");
    check(peek_w(base + 6) === 16'h0100, "preinstruction: +$06 format 0, $100");
    expect_cir(1'b0, R_CMD, 2, 32'h5555, "preinstruction");
    expect_cir(1'b1, R_RESP, 2, 32'h1C40, "preinstruction");
    expect_cir(1'b0, R_CTRL, 2, 32'h0002, "preinstruction: acknowledge");
    expect_end("preinstruction");

    // ======================================================================
    // A protocol violation -- UM 7.5.2.1. An undefined primitive gets the
    // midinstruction frame and vector 13; RTE out of it reads the response CIR
    // again and the dialogue goes on.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0034, HAND);           // vector 13
    poke_w(CODE + 0, 16'hF200);
    poke_w(CODE + 2, 16'h0777);
    poke_w(CODE + 4, 16'h7207);            // MOVEQ #7,D1
    poke_w(CODE + 6, 16'h60FE);
    poke_w(HAND + 0, 16'h4E73);            // RTE
    cp.push_resp(16'h0000);                // undefined
    cp.push_resp(16'h0802);
    reset_dut();
    run_until(HAND, 3000, reached);
    check(reached, "protocol violation: the handler for vector 13 runs");
    base = ISP0 - 32'h14;
    check(dut.u_seq.isp_q === base, "protocol violation: a ten-word frame");
    check(peek_w(base + 6) === 16'h9034,
          "protocol violation: +$06 format $9, vector offset $34");
    check(peek_l(base + 2) === CODE + 4, "protocol violation: +$02 the scanPC");
    check(peek_l(base + 8) === CODE, "protocol violation: +$08 the operation word's address");
    check(peek_w(base + 14) === 16'hF200, "protocol violation: +$0E the operation word");
    run_until(CODE + 6, 3000, reached);
    check(reached, "protocol violation: RTE goes back to the dialogue, which ends");
    check(dut.u_seq.dreg[1] === 32'h0000_0007, "protocol violation: and the next instruction runs");
    check(dut.u_seq.isp_q === ISP0, "protocol violation: the frame came off");
    expect_cir(1'b0, R_CMD, 2, 32'h0777, "protocol violation");
    expect_cir(1'b1, R_RESP, 2, 32'h0000, "protocol violation");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "protocol violation: after RTE");
    expect_end("protocol violation");

    // ======================================================================
    // No coprocessor -- UM 7.5.2.8: a bus error on the access that starts the
    // instruction is an F-line exception, not a bus error.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_002C, HAND);           // vector 11
    poke_w(CODE + 0, 16'hF400);            // cpGEN, CpID 2: nobody there
    poke_w(CODE + 2, 16'h0000);
    poke_w(CODE + 4, 16'h60FE);
    poke_w(HAND + 0, 16'h60FE);
    reset_dut();
    berr_en   = 1'b1;
    berr_base = 32'h0002_4000;             // CPU space, type 2, CpID 2
    berr_mask = 32'hFFFF_E000;
    run_until(HAND, 3000, reached);
    check(reached, "no coprocessor: the F-line handler runs");
    base = ISP0 - 32'h8;
    check(dut.u_seq.isp_q === base, "no coprocessor: a four-word frame");
    check(peek_l(base + 2) === CODE, "no coprocessor: +$02 the instruction");
    check(peek_w(base + 6) === 16'h002C, "no coprocessor: +$06 format 0, $02C");
    berr_en = 1'b0;


    // ======================================================================
    // cpBcc -- UM 7.2.2.1. The whole operation word to the condition CIR;
    // the verdict in a null primitive; the displacement is from the scanPC,
    // which is on the displacement word.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0,  16'hF281);           // cpBcc.W, condition 1
    poke_w(CODE + 2,  16'h0010);           // to CODE + 2 + $10
    poke_w(CODE + 4,  16'h60FE);           // not taken lands here
    poke_w(CODE + 18, 16'h60FE);           // taken lands here
    cp.push_resp(16'h0801);                // null, TF = 1: true
    reset_dut();
    run_until(CODE + 18, 3000, reached);
    check(reached, "cpBcc.W: taken");
    expect_cir(1'b0, R_COND, 2, 32'hF281, "cpBcc.W");
    expect_cir(1'b1, R_RESP, 2, 32'h0801, "cpBcc.W");
    expect_end("cpBcc.W");

    base_setup();
    poke_w(CODE + 0,  16'hF2C2);           // cpBcc.L, condition 2
    poke_l(CODE + 2,  32'h0000_0100);
    poke_w(CODE + 6,  16'h60FE);
    cp.push_resp(16'h0800);                // false
    reset_dut();
    run_until(CODE + 6, 3000, reached);
    check(reached, "cpBcc.L: not taken, both displacement words eaten");

    base_setup();
    poke_w(CODE + 0,  16'hF2C2);
    poke_l(CODE + 2,  32'h0000_0100);
    poke_w(CODE + 32'h102, 16'h60FE);
    cp.push_resp(16'h0801);
    reset_dut();
    run_until(CODE + 32'h102, 3000, reached);
    check(reached, "cpBcc.L: taken, from the first displacement word");

    // ======================================================================
    // cpScc -- UM 7.2.2.2: the condition word to the condition CIR, and the
    // byte at the effective address set or cleared after the dialogue. An
    // effective address with extension words follows the coprocessor's own.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0,  16'hF240);           // cpScc D0
    poke_w(CODE + 2,  16'h0003);
    poke_w(CODE + 4,  16'hF268);           // cpScc (d16,A0)
    poke_w(CODE + 6,  16'h0004);
    poke_w(CODE + 8,  16'h0010);           // d16
    poke_w(CODE + 10, 16'h60FE);
    cp.push_resp(16'h0801);                // true
    cp.push_resp(16'h0800);                // false
    reset_dut();
    dut.u_seq.dreg[0] = 32'h1234_5600;
    dut.u_seq.areg[0] = DATA;
    poke_w(DATA + 16, 16'hAAAA);
    run_until(CODE + 10, 3000, reached);
    check(reached, "cpScc: both end");
    check(dut.u_seq.dreg[0] === 32'h1234_56FF, "cpScc D0: the low byte set");
    check(peek_w(DATA + 16) === 16'h00AA, "cpScc (d16,A0): the byte cleared");
    expect_cir(1'b0, R_COND, 2, 32'h0003, "cpScc");
    expect_cir(1'b1, R_RESP, 2, 32'h0801, "cpScc");
    expect_cir(1'b0, R_COND, 2, 32'h0004, "cpScc");
    expect_cir(1'b1, R_RESP, 2, 32'h0800, "cpScc");
    expect_end("cpScc");

    // ======================================================================
    // cpDBcc -- UM 7.2.2.3. False and the counter not exhausted: branch.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0,  16'h7402);           // MOVEQ #2,D2
    poke_w(CODE + 2,  16'hF24A);           // cpDBcc D2
    poke_w(CODE + 4,  16'h0005);
    poke_w(CODE + 6,  16'hFFFC);           // back to CODE + 2
    poke_w(CODE + 8,  16'h60FE);
    cp.push_resp(16'h0800);                // false: D2 = 1, branch
    cp.push_resp(16'h0800);                // false: D2 = 0, branch
    cp.push_resp(16'h0801);                // true: out
    reset_dut();
    run_until(CODE + 8, 4000, reached);
    check(reached, "cpDBcc: the loop ends");
    check(dut.u_seq.dreg[2] === 32'h0000_0000, "cpDBcc: counted twice");
    check(cp.log_n == 6, "cpDBcc: three dialogues");

    base_setup();
    poke_w(CODE + 0,  16'h7400);           // MOVEQ #0,D2
    poke_w(CODE + 2,  16'hF24A);
    poke_w(CODE + 4,  16'h0005);
    poke_w(CODE + 6,  16'hFFFC);
    poke_w(CODE + 8,  16'h60FE);
    cp.push_resp(16'h0800);                // false: D2 = -1, fall through
    reset_dut();
    run_until(CODE + 8, 3000, reached);
    check(reached, "cpDBcc: the counter reaching -1 ends it");
    check(dut.u_seq.dreg[2] === 32'h0000_FFFF, "cpDBcc: the low word only");

    // ======================================================================
    // cpTRAPcc -- UM 7.5.2.4: true is vector 7 with the six-word frame, the
    // next instruction's address after the operand words.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_001C, HAND);           // vector 7
    poke_w(CODE + 0,  16'hF27B);           // cpTRAPcc.L
    poke_w(CODE + 2,  16'h0006);
    poke_l(CODE + 4,  32'hDEAD_BEEF);
    poke_w(CODE + 8,  16'h60FE);
    poke_w(HAND + 0,  16'h60FE);
    cp.push_resp(16'h0801);
    reset_dut();
    run_until(HAND, 3000, reached);
    check(reached, "cpTRAPcc.L: true traps");
    base = ISP0 - 32'hC;
    check(peek_w(base + 6) === 16'h201C, "cpTRAPcc: format 2, vector 7");
    check(peek_l(base + 2) === CODE + 8, "cpTRAPcc: +$02 the next instruction");
    check(peek_l(base + 8) === CODE, "cpTRAPcc: +$08 this one");

    base_setup();
    poke_w(CODE + 0,  16'hF27A);           // cpTRAPcc.W
    poke_w(CODE + 2,  16'h0006);
    poke_w(CODE + 4,  16'h1234);
    poke_w(CODE + 6,  16'h60FE);
    cp.push_resp(16'h0800);
    reset_dut();
    run_until(CODE + 6, 3000, reached);
    check(reached, "cpTRAPcc.W: false goes on past the operand word");


    // ======================================================================
    // cpSAVE -- UM 7.2.3.3. Not ready first, which restarts the instruction
    // (UM 7.2.3.2.2); then a valid eight-byte state to -(A0): the whole frame
    // below A0, the format word at the bottom, the state from the top down.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0, 16'hF320);            // cpSAVE -(A0)
    poke_w(CODE + 2, 16'h60FE);
    cp.push_save(16'h0100);                // not ready
    cp.push_save(16'h1808);                // format $18, eight bytes
    cp.push_opnd(32'h1111_1111);
    cp.push_opnd(32'h2222_2222);
    reset_dut();
    dut.u_seq.areg[0] = DATA + 32'h100;
    run_until(CODE + 2, 3000, reached);
    check(reached, "cpSAVE: ends");
    check(dut.u_seq.areg[0] === DATA + 32'h100 - 32'd12, "cpSAVE -(A0): down by twelve");
    check(peek_l(DATA + 32'hF4) === 32'h1808_0000, "cpSAVE: the format word at the bottom");
    check(peek_l(DATA + 32'hFC) === 32'h1111_1111, "cpSAVE: the first long word read goes highest");
    check(peek_l(DATA + 32'hF8) === 32'h2222_2222, "cpSAVE: the second below it");
    expect_cir(1'b1, R_SAVE, 2, 32'h0100, "cpSAVE");
    expect_cir(1'b1, R_SAVE, 2, 32'h1808, "cpSAVE: read again");
    expect_cir(1'b1, R_OPND, 4, 32'h1111_1111, "cpSAVE");
    expect_cir(1'b1, R_OPND, 4, 32'h2222_2222, "cpSAVE");
    expect_end("cpSAVE");

    // ... and cpRESTORE (A0)+ of the same frame: the format word to the
    // restore CIR, the coprocessor's answer read back, the state in ascending
    // order, and A0 past the frame.
    base_setup();
    poke_w(CODE + 0, 16'hF358);            // cpRESTORE (A0)+
    poke_w(CODE + 2, 16'h60FE);
    poke_l(DATA + 0, 32'h1808_0000);
    poke_l(DATA + 4, 32'h3333_3333);
    poke_l(DATA + 8, 32'h4444_4444);
    reset_dut();
    dut.u_seq.areg[0] = DATA;
    run_until(CODE + 2, 3000, reached);
    check(reached, "cpRESTORE: ends");
    check(dut.u_seq.areg[0] === DATA + 32'd12, "cpRESTORE (A0)+: past the frame");
    expect_cir(1'b0, R_REST, 2, 32'h1808, "cpRESTORE");
    expect_cir(1'b1, R_REST, 2, 32'h1808, "cpRESTORE");
    expect_cir(1'b0, R_OPND, 4, 32'h3333_3333, "cpRESTORE");
    expect_cir(1'b0, R_OPND, 4, 32'h4444_4444, "cpRESTORE");
    expect_end("cpRESTORE");

    // An empty save to a control address is the format word alone.
    base_setup();
    poke_w(CODE + 0, 16'hF311);            // cpSAVE (A1)
    poke_w(CODE + 2, 16'h60FE);
    poke_l(DATA + 32, 32'hFFFF_FFFF);
    reset_dut();
    dut.u_seq.areg[1] = DATA + 32;
    run_until(CODE + 2, 3000, reached);
    check(reached && peek_l(DATA + 32) === 32'h0000_0000, "cpSAVE: empty");

    // An invalid format word: abort, then a format error with the four-word
    // frame -- UM 7.5.1.5.
    base_setup();
    poke_l(32'h0000_0038, HAND);           // vector 14
    poke_w(CODE + 0, 16'hF311);
    poke_w(CODE + 2, 16'h60FE);
    poke_w(HAND + 0, 16'h60FE);
    cp.push_save(16'h0200);
    reset_dut();
    dut.u_seq.areg[1] = DATA;
    run_until(HAND, 3000, reached);
    check(reached, "cpSAVE invalid: format error");
    check(peek_w(ISP0 - 8 + 6) === 16'h0038, "cpSAVE invalid: format 0, vector 14");
    check(peek_l(ISP0 - 8 + 2) === CODE, "cpSAVE invalid: the instruction's address");
    expect_cir(1'b1, R_SAVE, 2, 32'h0200, "cpSAVE invalid");
    expect_cir(1'b0, R_CTRL, 2, 32'h0001, "cpSAVE invalid: abort");
    expect_end("cpSAVE invalid");

    // A restore whose length in memory is not a multiple of four -- UM
    // 7.5.2.7: written, read back, and only then aborted.
    base_setup();
    poke_l(32'h0000_0038, HAND);
    poke_w(CODE + 0, 16'hF350);            // cpRESTORE (A0)
    poke_w(CODE + 2, 16'h60FE);
    poke_w(HAND + 0, 16'h60FE);
    poke_l(DATA + 0, 32'h1806_0000);
    reset_dut();
    dut.u_seq.areg[0] = DATA;
    run_until(HAND, 3000, reached);
    check(reached, "cpRESTORE bad length: format error");
    expect_cir(1'b0, R_REST, 2, 32'h1806, "cpRESTORE bad length");
    expect_cir(1'b1, R_REST, 2, 32'h1806, "cpRESTORE bad length");
    expect_cir(1'b0, R_CTRL, 2, 32'h0001, "cpRESTORE bad length: abort");
    expect_end("cpRESTORE bad length");

    // Both are privileged, checked before any CIR is touched -- UM 7.2.3.3.2.
    base_setup();
    poke_l(32'h0000_0020, HAND);           // vector 8
    poke_w(CODE + 0, 16'h46FC);            // MOVE #$0000,SR: user mode
    poke_w(CODE + 2, 16'h0000);
    poke_w(CODE + 4, 16'hF311);            // cpSAVE (A1)
    poke_w(CODE + 6, 16'h60FE);
    poke_w(HAND + 0, 16'h60FE);
    reset_dut();
    run_until(HAND, 3000, reached);
    check(reached, "cpSAVE in user mode: privilege violation");
    expect_end("cpSAVE in user mode: no CIR access");

    // ======================================================================
    // Busy -- UM 7.4.3: the instruction is started again from the beginning,
    // command word and all.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0, 16'hF200);
    poke_w(CODE + 2, 16'h00AA);
    poke_w(CODE + 4, 16'h60FE);
    cp.push_resp(16'hA400);                // busy
    cp.push_resp(16'h0802);
    reset_dut();
    run_until(CODE + 4, 3000, reached);
    check(reached, "busy: the instruction completes the second time");
    expect_cir(1'b0, R_CMD, 2, 32'h00AA, "busy");
    expect_cir(1'b1, R_RESP, 2, 32'hA400, "busy");
    expect_cir(1'b0, R_CMD, 2, 32'h00AA, "busy: the command written again");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "busy");
    expect_end("busy");

    // ======================================================================
    // Supervisor check in user mode -- UM 7.4.5: abort, then a privilege
    // violation whose frame points at the instruction.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0020, HAND);
    poke_w(CODE + 0, 16'h46FC);
    poke_w(CODE + 2, 16'h0000);
    poke_w(CODE + 4, 16'hF200);
    poke_w(CODE + 6, 16'h0042);
    poke_w(CODE + 8, 16'h60FE);
    poke_w(HAND + 0, 16'h60FE);
    cp.push_resp(16'h8400);
    reset_dut();
    run_until(HAND, 3000, reached);
    check(reached, "supervisor check: privilege violation in user mode");
    check(peek_l(ISP0 - 8 + 2) === CODE + 4, "supervisor check: the instruction's address");
    expect_cir(1'b0, R_CMD, 2, 32'h0042, "supervisor check");
    expect_cir(1'b1, R_RESP, 2, 32'h8400, "supervisor check");
    expect_cir(1'b0, R_CTRL, 2, 32'h0001, "supervisor check: abort");
    expect_end("supervisor check");

    // ======================================================================
    // The stream, the operation word, and the program counter -- UM 7.4.6,
    // 7.4.7 and 7.4.2. Six bytes of extension words: a long word and a word.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0,  16'hF200);
    poke_w(CODE + 2,  16'h0100);
    poke_l(CODE + 4,  32'hABCD_EF01);
    poke_w(CODE + 8,  16'h2345);
    poke_w(CODE + 10, 16'h60FE);
    cp.push_resp(16'hC700);                // CA, PC, transfer operation word
    cp.push_resp(16'h8F06);                // CA, from the stream, six bytes
    cp.push_resp(16'h0802);
    reset_dut();
    run_until(CODE + 10, 3000, reached);
    check(reached, "stream: the scanPC ends past the six bytes");
    expect_cir(1'b0, R_CMD, 2, 32'h0100, "stream");
    expect_cir(1'b1, R_RESP, 2, 32'hC700, "stream");
    expect_cir(1'b0, R_IADR, 4, CODE, "PC bit: the operation word's address first");
    expect_cir(1'b0, R_OPW, 2, 32'hF200, "transfer operation word");
    expect_cir(1'b1, R_RESP, 2, 32'h8F06, "stream");
    expect_cir(1'b0, R_OPND, 4, 32'hABCD_EF01, "stream: a long word");
    expect_cir(1'b0, R_OPND, 2, 32'h2345, "stream: and a word");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "stream");
    expect_end("stream");

    // ======================================================================
    // Evaluate and transfer effective address -- UM 7.4.8 -- then write to it
    // -- UM 7.4.10 -- and a non-control-alterable address refused.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0,  16'hF228);           // cpGEN (d16,A0)
    poke_w(CODE + 2,  16'h0200);
    poke_w(CODE + 4,  16'h0040);           // d16
    poke_w(CODE + 6,  16'h60FE);
    cp.push_resp(16'h8A00);                // CA, evaluate and transfer <ea>
    cp.push_resp(16'hA003);                // CA, write 3 bytes to it
    cp.push_resp(16'h0802);
    cp.push_opnd(32'h5566_7700);
    poke_l(DATA + 32'h40, 32'h0000_0000);
    reset_dut();
    dut.u_seq.areg[0] = DATA;
    run_until(CODE + 6, 3000, reached);
    check(reached, "evaluate <ea>: ends past d16");
    check(peek_l(DATA + 32'h40) === 32'h5566_7700, "write to previous <ea>: three bytes");
    expect_cir(1'b0, R_CMD, 2, 32'h0200, "evaluate <ea>");
    expect_cir(1'b1, R_RESP, 2, 32'h8A00, "evaluate <ea>");
    expect_cir(1'b0, R_OADR, 4, DATA + 32'h40, "evaluate <ea>: the address");
    expect_cir(1'b1, R_RESP, 2, 32'hA003, "write previous");
    expect_cir(1'b1, R_OPND, 3, 32'h0055_6677, "write previous: three bytes");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "write previous");
    expect_end("evaluate <ea>");

    base_setup();
    poke_l(32'h0000_002C, HAND);           // vector 11
    poke_w(CODE + 0,  16'hF200);           // cpGEN D0: not control alterable
    poke_w(CODE + 2,  16'h0300);
    poke_w(CODE + 4,  16'h60FE);
    poke_w(HAND + 0,  16'h60FE);
    cp.push_resp(16'h8A00);
    reset_dut();
    run_until(HAND, 3000, reached);
    check(reached, "evaluate <ea> of D0: F-line");
    expect_cir(1'b0, R_CMD, 2, 32'h0300, "evaluate <ea> of D0");
    expect_cir(1'b1, R_RESP, 2, 32'h8A00, "evaluate <ea> of D0");
    expect_cir(1'b0, R_CTRL, 2, 32'h0001, "evaluate <ea> of D0: abort");
    expect_end("evaluate <ea> of D0");

    // ======================================================================
    // Take address and transfer data -- UM 7.4.11 -- and the top of the stack
    // -- UM 7.4.12, a byte stepping A7 by two.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0,  16'hF200);
    poke_w(CODE + 2,  16'h0400);
    poke_w(CODE + 4,  16'h60FE);
    poke_l(DATA + 32'h80, 32'h8182_8384);
    poke_w(DATA + 32'h84, 16'h8586);
    cp.push_resp(16'h8506);                // CA, take address, 6 bytes to CP
    cp.push_resp(16'hAE01);                // CA, a byte from CP to -(A7)
    cp.push_resp(16'h8E02);                // CA, a word from (A7)+ to CP
    cp.push_resp(16'h0802);
    cp.push_oadr(DATA + 32'h80);
    cp.push_opnd(32'h7700_0000);
    reset_dut();
    run_until(CODE + 4, 3000, reached);
    check(reached, "take address, top of stack: ends");
    check(dut.u_seq.isp_q === ISP0, "top of stack: a byte pushed and a word popped");
    check(peek_w(ISP0 - 2) >> 8 === 16'h0077,
          "top of stack: the byte in the high half of the word A7 stepped down by");
    expect_cir(1'b0, R_CMD, 2, 32'h0400, "take address");
    expect_cir(1'b1, R_RESP, 2, 32'h8506, "take address");
    expect_cir(1'b1, R_OADR, 4, DATA + 32'h80, "take address");
    expect_cir(1'b0, R_OPND, 4, 32'h8182_8384, "take address: a long word");
    expect_cir(1'b0, R_OPND, 2, 32'h8586, "take address: and a word");
    expect_cir(1'b1, R_RESP, 2, 32'hAE01, "top of stack");
    expect_cir(1'b1, R_OPND, 1, 32'h77, "top of stack: the byte");
    expect_cir(1'b1, R_RESP, 2, 32'h8E02, "top of stack");
    expect_cir(1'b0, R_OPND, 2, {16'd0, peek_w(ISP0 - 2)}, "top of stack: the word");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "top of stack");
    expect_end("top of stack");

    // ======================================================================
    // Control registers -- UM 7.4.14: VBR out and in, and a code table 7-5
    // does not have, which is a protocol violation.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0034, HAND);           // vector 13
    poke_w(CODE + 0,  16'hF200);
    poke_w(CODE + 2,  16'h0500);
    poke_w(CODE + 4,  16'h60FE);
    poke_w(HAND + 0,  16'h60FE);
    cp.push_resp(16'h8D00);                // CA, control register to CP
    cp.push_resp(16'hAD00);                // CA, control register from CP
    cp.push_resp(16'h8D00);                // CA, with a bad select code
    cp.push_rsel(16'h0801);                // VBR
    cp.push_rsel(16'h0801);
    cp.push_rsel(16'h0005);                // nothing
    cp.push_opnd(32'h0000_0000);           // VBR back to zero
    reset_dut();
    dut.u_seq.vbr_q = 32'h0000_0000;
    run_until(HAND, 3000, reached);
    check(reached, "control register: a bad code is a protocol violation");
    expect_cir(1'b0, R_CMD, 2, 32'h0500, "control register");
    expect_cir(1'b1, R_RESP, 2, 32'h8D00, "control register");
    expect_cir(1'b1, R_RSEL, 2, 32'h0801, "control register");
    expect_cir(1'b0, R_OPND, 4, 32'h0000_0000, "control register: VBR out");
    expect_cir(1'b1, R_RESP, 2, 32'hAD00, "control register");
    expect_cir(1'b1, R_RSEL, 2, 32'h0801, "control register");
    expect_cir(1'b1, R_OPND, 4, 32'h0000_0000, "control register: VBR in");
    expect_cir(1'b1, R_RESP, 2, 32'h8D00, "control register");
    expect_cir(1'b1, R_RSEL, 2, 32'h0005, "control register: a bad code");
    expect_end("control register");

    // ======================================================================
    // Multiple main processor registers -- UM 7.4.15 -- D1, D6 and A3.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0,  16'hF200);
    poke_w(CODE + 2,  16'h0600);
    poke_w(CODE + 4,  16'h60FE);
    cp.push_resp(16'h8600);                // CA, main registers to CP
    cp.push_resp(16'hA600);                // CA, main registers from CP
    cp.push_resp(16'h0802);
    cp.push_rsel(16'h0842);                // A3, D6, D1
    cp.push_rsel(16'h0001);                // D0
    cp.push_opnd(32'h0D0D_0D0D);
    reset_dut();
    dut.u_seq.dreg[1] = 32'h1111_1111;
    dut.u_seq.dreg[6] = 32'h6666_6666;
    dut.u_seq.areg[3] = 32'hA3A3_A3A3;
    run_until(CODE + 4, 3000, reached);
    check(reached, "multiple registers: ends");
    check(dut.u_seq.dreg[0] === 32'h0D0D_0D0D, "multiple registers: D0 in");
    expect_cir(1'b0, R_CMD, 2, 32'h0600, "multiple registers");
    expect_cir(1'b1, R_RESP, 2, 32'h8600, "multiple registers");
    expect_cir(1'b1, R_RSEL, 2, 32'h0842, "multiple registers");
    expect_cir(1'b0, R_OPND, 4, 32'h1111_1111, "multiple registers: D1");
    expect_cir(1'b0, R_OPND, 4, 32'h6666_6666, "multiple registers: D6");
    expect_cir(1'b0, R_OPND, 4, 32'hA3A3_A3A3, "multiple registers: A3");
    expect_cir(1'b1, R_RESP, 2, 32'hA600, "multiple registers");
    expect_cir(1'b1, R_RSEL, 2, 32'h0001, "multiple registers");
    expect_cir(1'b1, R_OPND, 4, 32'h0D0D_0D0D, "multiple registers: D0");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "multiple registers");
    expect_end("multiple registers");

    // ======================================================================
    // Multiple coprocessor registers -- UM 7.4.16 and figure 7-38: two
    // twelve-byte operands to -(A1), each written upwards from where A1 has
    // stepped down to.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0,  16'hF221);           // cpGEN -(A1)
    poke_w(CODE + 2,  16'h0700);
    poke_w(CODE + 4,  16'h60FE);
    cp.push_resp(16'hA10C);                // CA, from CP, twelve bytes each
    cp.push_resp(16'h0802);
    cp.push_rsel(16'h0180);                // two ones
    cp.push_opnd(32'h0000_0001); cp.push_opnd(32'h0000_0002);
    cp.push_opnd(32'h0000_0003);
    cp.push_opnd(32'h1000_0001); cp.push_opnd(32'h1000_0002);
    cp.push_opnd(32'h1000_0003);
    reset_dut();
    dut.u_seq.areg[1] = DATA + 32'h40;
    run_until(CODE + 4, 3000, reached);
    check(reached, "multiple coprocessor registers: ends");
    check(dut.u_seq.areg[1] === DATA + 32'h40 - 32'd24, "-(A1): down by 24");
    check(peek_l(DATA + 32'h34) === 32'h0000_0001 &&
          peek_l(DATA + 32'h3C) === 32'h0000_0003,
          "figure 7-38: the first operand just below the initial A1");
    check(peek_l(DATA + 32'h28) === 32'h1000_0001 &&
          peek_l(DATA + 32'h30) === 32'h1000_0003,
          "figure 7-38: the second below it, at the final A1");


    // ======================================================================
    // Transfer status register and scanPC -- UM 7.4.17. Out: the scanPC and
    // then the status register. In: the status register, then a new scanPC,
    // which moves the program on to wherever the coprocessor says.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0,  16'hF200);
    poke_w(CODE + 2,  16'h0800);
    poke_w(CODE + 4,  16'h7011);           // MOVEQ #$11,D0 -- skipped
    poke_w(CODE + 6,  16'h60FE);
    poke_w(CODE + 32'h40, 16'h7022);       // MOVEQ #$22,D0 -- where it goes
    poke_w(CODE + 32'h42, 16'h60FE);
    cp.push_resp(16'h8300);                // CA, SR and scanPC to CP
    cp.push_resp(16'hA300);                // CA, SR and scanPC from CP
    cp.push_resp(16'h0802);
    cp.push_opnd(32'h2715_0000);           // the SR, in the top half
    cp.push_iadr(CODE + 32'h40);
    reset_dut();
    run_until(CODE + 32'h42, 3000, reached);
    check(reached, "SR and scanPC: the program goes where the scanPC says");
    check(dut.u_seq.dreg[0] === 32'h0000_0022, "SR and scanPC: and the instruction there runs");
    // $2715 went in; the MOVEQ at the new scanPC then cleared N, Z, V and C.
    check(dut.u_seq.sr_q === 16'h2710, "SR and scanPC: the status register loaded");
    expect_cir(1'b0, R_CMD, 2, 32'h0800, "SR and scanPC");
    expect_cir(1'b1, R_RESP, 2, 32'h8300, "SR and scanPC");
    expect_cir(1'b0, R_IADR, 4, CODE + 4, "SR and scanPC: the scanPC out");
    expect_cir(1'b0, R_OPND, 2, 32'h2700, "SR and scanPC: the SR out");
    expect_cir(1'b1, R_RESP, 2, 32'hA300, "SR and scanPC");
    expect_cir(1'b1, R_OPND, 2, 32'h2715, "SR and scanPC: the SR in");
    expect_cir(1'b1, R_IADR, 4, CODE + 32'h40, "SR and scanPC: the scanPC in");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "SR and scanPC");
    expect_end("SR and scanPC");

    // ======================================================================
    // Take midinstruction exception -- UM 7.4.19: acknowledge, the ten-word
    // frame, and after RTE the response CIR is read again.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0104, HAND);           // vector 65
    poke_w(CODE + 0,  16'hF200);
    poke_w(CODE + 2,  16'h0900);
    poke_w(CODE + 4,  16'h60FE);
    poke_w(HAND + 0,  16'h4E73);           // RTE
    cp.push_resp(16'h1D41);                // take midinstruction, vector 65
    cp.push_resp(16'h0802);
    reset_dut();
    run_until(HAND, 3000, reached);
    check(reached, "midinstruction: the handler runs");
    base = ISP0 - 32'h14;
    check(peek_w(base + 6) === 16'h9104, "midinstruction: format $9, $104");
    run_until(CODE + 4, 3000, reached);
    check(reached, "midinstruction: RTE, and the dialogue ends");
    expect_cir(1'b0, R_CMD, 2, 32'h0900, "midinstruction");
    expect_cir(1'b1, R_RESP, 2, 32'h1D41, "midinstruction");
    expect_cir(1'b0, R_CTRL, 2, 32'h0002, "midinstruction: acknowledge");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "midinstruction: after RTE");
    expect_end("midinstruction");

    // ======================================================================
    // Take postinstruction exception -- UM 7.4.20: the six-word frame with
    // the scanPC as the program counter, so RTE goes on to the next
    // instruction.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0108, HAND);           // vector 66
    poke_w(CODE + 0,  16'hF200);
    poke_w(CODE + 2,  16'h0A00);
    poke_w(CODE + 4,  16'h7033);           // MOVEQ #$33,D0
    poke_w(CODE + 6,  16'h60FE);
    poke_w(HAND + 0,  16'h4E73);
    cp.push_resp(16'h1E42);
    reset_dut();
    run_until(CODE + 6, 3000, reached);
    check(reached && dut.u_seq.dreg[0] === 32'h0000_0033,
          "postinstruction: RTE goes on to the next instruction");
    base = ISP0 - 32'hC;
    check(peek_w(base + 6) === 16'h2108, "postinstruction: format 2, $108");
    check(peek_l(base + 2) === CODE + 4, "postinstruction: +$02 the scanPC");
    check(peek_l(base + 8) === CODE, "postinstruction: +$08 the operation word");

    // ======================================================================
    // An interrupt in the dialogue -- UM 7.5.2.6: a null primitive with CA
    // and IA set, with a request pending, is serviced with the midinstruction
    // frame, and RTE goes back to the response CIR.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0074, HAND);           // autovector 5
    poke_w(CODE + 0,  16'h46FC);           // MOVE #$2000,SR: mask 0
    poke_w(CODE + 2,  16'h2000);
    poke_w(CODE + 4,  16'hF200);
    poke_w(CODE + 6,  16'h0B00);
    poke_w(CODE + 8,  16'h60FE);
    poke_w(HAND + 0,  16'h4E73);           // RTE
    cp.push_resp(16'h8900);                // null, CA, IA
    cp.push_resp(16'h0802);
    reset_dut();
    iacks = 0;
    // Raised once the dialogue has started, so that it is the null primitive
    // and not the decode arm that takes it.
    wait (cp.log_n == 1);
    ipl_n_i = ~3'd5;
    run_until(HAND, 3000, reached);
    check(reached && iacks == 1, "IA: the interrupt is taken inside the instruction");
    base = ISP0 - 32'h14;
    check(peek_w(base + 6) === 16'h9074, "IA: format $9, autovector 5");
    check(peek_w(base + 0) === 16'h2000, "IA: +$00 the mask the program ran under");
    check(peek_l(base + 8) === CODE + 4, "IA: +$08 the coprocessor instruction");
    run_until(CODE + 8, 3000, reached);
    check(reached, "IA: RTE, and the dialogue ends");
    expect_cir(1'b0, R_CMD, 2, 32'h0B00, "IA");
    expect_cir(1'b1, R_RESP, 2, 32'h8900, "IA");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "IA: after RTE");
    expect_end("IA");

    // ... and on the master stack, with the throwaway frame on the interrupt
    // stack -- UM 6.1.9 and 7.5.2.6.
    base_setup();
    poke_l(32'h0000_0074, HAND);
    poke_w(CODE + 0,  16'h46FC);           // MOVE #$3000,SR: M set, mask 0
    poke_w(CODE + 2,  16'h3000);
    poke_w(CODE + 4,  16'hF200);
    poke_w(CODE + 6,  16'h0C00);
    poke_w(CODE + 8,  16'h60FE);
    poke_w(HAND + 0,  16'h4E73);
    cp.push_resp(16'h8900);
    cp.push_resp(16'h0802);
    reset_dut();
    dut.u_seq.msp_q = ISP0 - 32'h200;
    wait (cp.log_n == 1);
    ipl_n_i = ~3'd5;
    run_until(HAND, 3000, reached);
    check(reached, "IA, master: the interrupt is taken");
    check(peek_w(ISP0 - 32'h200 - 32'h14 + 6) === 16'h9074,
          "IA, master: the midinstruction frame on the master stack");
    check(peek_w(ISP0 - 8 + 6) === 16'h1074,
          "IA, master: the throwaway on the interrupt stack");
    run_until(CODE + 8, 3000, reached);
    check(reached, "IA, master: RTE unwinds both, and the dialogue ends");
    check(dut.u_seq.msp_q === ISP0 - 32'h200 && dut.u_seq.isp_q === ISP0,
          "IA, master: both stacks back");

    // ======================================================================
    // A trace pending keeps a general instruction's dialogue open until the
    // coprocessor says it has finished -- UM 7.5.2.5 -- and then the trace is
    // taken.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0024, HAND);           // vector 9
    poke_w(CODE + 0,  16'h46FC);           // MOVE #$A700,SR: trace every instruction
    poke_w(CODE + 2,  16'hA700);
    poke_w(CODE + 4,  16'hF200);
    poke_w(CODE + 6,  16'h0D00);
    poke_w(CODE + 8,  16'h60FE);
    poke_w(HAND + 0,  16'h60FE);
    cp.push_resp(16'h0800);                // null, CA clear, PF clear: not finished
    cp.push_resp(16'h8C00);                // D0 to the coprocessor, CA clear
    cp.push_resp(16'h0802);                // finished
    reset_dut();
    run_until(HAND, 4000, reached);
    check(reached, "trace: the trace is taken");
    check(peek_l(ISP0 - 12 + 8) === CODE + 4, "trace: of the coprocessor instruction");
    check(peek_l(ISP0 - 12 + 2) === CODE + 8, "trace: the next instruction in the frame");
    expect_cir(1'b0, R_CMD, 2, 32'h0D00, "trace");
    expect_cir(1'b1, R_RESP, 2, 32'h0800, "trace");
    expect_cir(1'b1, R_RESP, 2, 32'h8C00, "trace: read again");
    expect_cir(1'b0, R_OPND, 4, 32'h0000_0000, "trace: served");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "trace: read again, finished");
    expect_end("trace");

    // ======================================================================
    // A bus error on an interface register after the first -- UM 7.5.2.8 --
    // is a bus error. The long frame; RTE reruns the access and the dialogue
    // carries on from it.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0008, HAND);           // vector 2
    poke_w(CODE + 0,  16'hF200);
    poke_w(CODE + 2,  16'h0E00);
    poke_w(CODE + 4,  16'h60FE);
    poke_w(HAND + 0,  16'h4E73);           // RTE, reruns the access
    cp.push_resp(16'h8C05);                // CA, D5 to the coprocessor
    cp.push_resp(16'h0802);
    reset_dut();
    dut.u_seq.dreg[5] = 32'h5555_AAAA;
    berr_en   = 1'b1;
    berr_base = 32'h0002_2010;             // the operand CIR
    berr_mask = 32'hFFFF_FFFC;
    run_until(HAND, 3000, reached);
    check(reached, "CIR bus error: the bus error handler runs");
    base = ISP0 - 32'h5C;
    check(peek_w(base + 6) === 16'hB008, "CIR bus error: the long frame");
    check(peek_l(base + 16) === 32'h0002_2010, "CIR bus error: +$10 the CIR's address");
    berr_en = 1'b0;
    run_until(CODE + 4, 3000, reached);
    check(reached, "CIR bus error: RTE, and the instruction ends");
    // The model cannot see BERR, so it logs the faulted write as well as the
    // rerun: the same access twice.
    expect_cir(1'b0, R_CMD, 2, 32'h0E00, "CIR bus error");
    expect_cir(1'b1, R_RESP, 2, 32'h8C05, "CIR bus error");
    expect_cir(1'b0, R_OPND, 4, 32'h5555_AAAA, "CIR bus error: the faulted write");
    expect_cir(1'b0, R_OPND, 4, 32'h5555_AAAA, "CIR bus error: the rerun");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "CIR bus error");
    expect_end("CIR bus error");

    // ======================================================================
    // Evaluate effective address and transfer data to registers and from an
    // immediate -- UM 7.4.9: a byte into D2's low byte, a word sign extended
    // into A4, a byte immediate and a six-byte one.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0,  16'hF202);           // cpGEN D2
    poke_w(CODE + 2,  16'h0F00);
    poke_w(CODE + 4,  16'hF20C);           // cpGEN A4
    poke_w(CODE + 6,  16'h0F01);
    poke_w(CODE + 8,  16'hF23C);           // cpGEN #imm
    poke_w(CODE + 10, 16'h0F02);
    poke_w(CODE + 12, 16'h00C3);           // the byte immediate
    poke_w(CODE + 14, 16'hF23C);
    poke_w(CODE + 16, 16'h0F03);
    poke_l(CODE + 18, 32'h1020_3040);      // six bytes of immediate
    poke_w(CODE + 22, 16'h5060);
    poke_w(CODE + 24, 16'h60FE);
    cp.push_resp(16'hB701);                // CA, from CP, a byte
    cp.push_resp(16'h0802);
    cp.push_resp(16'hB702);                // CA, from CP, a word
    cp.push_resp(16'h0802);
    cp.push_resp(16'h9701);                // CA, to CP, a byte
    cp.push_resp(16'h0802);
    cp.push_resp(16'h9706);                // CA, to CP, six bytes
    cp.push_resp(16'h0802);
    cp.push_opnd(32'h9900_0000);
    cp.push_opnd(32'h8001_0000);
    reset_dut();
    dut.u_seq.dreg[2] = 32'h1111_1111;
    run_until(CODE + 24, 4000, reached);
    check(reached, "registers and immediates: all four end");
    check(dut.u_seq.dreg[2] === 32'h1111_1199, "D2: only the low byte");
    check(dut.u_seq.areg[4] === 32'hFFFF_8001, "A4: sign extended");
    expect_cir(1'b0, R_CMD, 2, 32'h0F00, "D2");
    expect_cir(1'b1, R_RESP, 2, 32'hB701, "D2");
    expect_cir(1'b1, R_OPND, 1, 32'h99, "D2");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "D2");
    expect_cir(1'b0, R_CMD, 2, 32'h0F01, "A4");
    expect_cir(1'b1, R_RESP, 2, 32'hB702, "A4");
    expect_cir(1'b1, R_OPND, 2, 32'h8001, "A4");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "A4");
    expect_cir(1'b0, R_CMD, 2, 32'h0F02, "#byte");
    expect_cir(1'b1, R_RESP, 2, 32'h9701, "#byte");
    expect_cir(1'b0, R_OPND, 1, 32'hC3, "#byte: the low byte of its word");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "#byte");
    expect_cir(1'b0, R_CMD, 2, 32'h0F03, "#six");
    expect_cir(1'b1, R_RESP, 2, 32'h9706, "#six");
    expect_cir(1'b0, R_OPND, 4, 32'h1020_3040, "#six");
    expect_cir(1'b0, R_OPND, 2, 32'h5060, "#six");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "#six");
    expect_end("registers and immediates");

    // Wrong class: a data register where the primitive asked for memory --
    // abort, F-line. And a general-only primitive in a conditional
    // instruction -- a protocol violation.
    base_setup();
    poke_l(32'h0000_002C, HAND);           // vector 11
    poke_w(CODE + 0,  16'hF200);           // cpGEN D0
    poke_w(CODE + 2,  16'h0F04);
    poke_w(CODE + 4,  16'h60FE);
    poke_w(HAND + 0,  16'h60FE);
    cp.push_resp(16'h9604);                // memory (110), four bytes
    reset_dut();
    run_until(HAND, 3000, reached);
    check(reached, "wrong class: F-line");
    li = 2;
    expect_cir(1'b0, R_CTRL, 2, 32'h0001, "wrong class: abort");
    expect_end("wrong class");

    base_setup();
    poke_l(32'h0000_0034, HAND);           // vector 13
    poke_w(CODE + 0,  16'hF281);           // cpBcc.W
    poke_w(CODE + 2,  16'h0010);
    poke_w(CODE + 4,  16'h60FE);
    poke_w(HAND + 0,  16'h60FE);
    cp.push_resp(16'h9704);                // evaluate <ea> and transfer: general only
    reset_dut();
    run_until(HAND, 3000, reached);
    check(reached, "general-only primitive in cpBcc: protocol violation");
    check(peek_w(ISP0 - 32'h14 + 6) === 16'h9034, "protocol violation: format $9");


    // ======================================================================
    // Busy with an interrupt pending -- UM 7.4.3: "it services pending
    // interrupts using a preinstruction exception stack frame", four words
    // with the operation word's address, and then starts the instruction
    // again. Not ready on cpSAVE does the same -- UM 7.5.2.6.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0074, HAND);           // autovector 5
    poke_w(CODE + 0,  16'h46FC);
    poke_w(CODE + 2,  16'h2000);
    poke_w(CODE + 4,  16'hF200);
    poke_w(CODE + 6,  16'h1100);
    poke_w(CODE + 8,  16'h60FE);
    poke_w(HAND + 0,  16'h4E73);
    cp.push_resp(16'hA400);                // busy
    cp.push_resp(16'h0802);
    reset_dut();
    iacks = 0;
    wait (cp.log_n == 1);
    ipl_n_i = ~3'd5;
    run_until(HAND, 3000, reached);
    check(reached && iacks == 1, "busy: the interrupt is taken");
    check(peek_w(ISP0 - 8 + 6) === 16'h0074, "busy: the four-word frame");
    check(peek_l(ISP0 - 8 + 2) === CODE + 4, "busy: with the operation word's address");
    run_until(CODE + 8, 3000, reached);
    check(reached, "busy: RTE starts the instruction again, and it ends");
    expect_cir(1'b0, R_CMD, 2, 32'h1100, "busy, interrupted");
    expect_cir(1'b1, R_RESP, 2, 32'hA400, "busy, interrupted");
    expect_cir(1'b0, R_CMD, 2, 32'h1100, "busy, interrupted: started again");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "busy, interrupted");
    expect_end("busy, interrupted");

    // MOVEC with a control register code the MC68020 does not have is an
    // illegal instruction -- UM 6.1.5.
    base_setup();
    poke_l(32'h0000_0010, HAND);           // vector 4
    poke_w(CODE + 0,  16'h4E7A);           // MOVEC $805,D0
    poke_w(CODE + 2,  16'h0805);
    poke_w(CODE + 4,  16'h60FE);
    poke_w(HAND + 0,  16'h60FE);
    reset_dut();
    run_until(HAND, 3000, reached);
    check(reached, "MOVEC of an undefined control register: illegal instruction");
    check(peek_l(ISP0 - 8 + 2) === CODE, "MOVEC: the frame points at it");


    // cpRESTORE of an immediate frame: the state comes out of the instruction
    // stream, and the program goes on after it.
    base_setup();
    poke_w(CODE + 0,  16'hF37C);           // cpRESTORE #<frame>
    poke_l(CODE + 2,  32'h1804_0000);
    poke_l(CODE + 6,  32'h5A5A_A5A5);
    poke_w(CODE + 10, 16'h60FE);
    reset_dut();
    run_until(CODE + 10, 3000, reached);
    check(reached, "cpRESTORE #: the program goes on past the frame");
    expect_cir(1'b0, R_REST, 2, 32'h1804, "cpRESTORE #");
    expect_cir(1'b1, R_REST, 2, 32'h1804, "cpRESTORE #");
    expect_cir(1'b0, R_OPND, 4, 32'h5A5A_A5A5, "cpRESTORE #: the state");
    expect_end("cpRESTORE #");


    // ======================================================================
    // The MC68881's port: its sixteen-bit registers answer with DSACK1 alone,
    // on D31-D16 whatever A1 says (MC68881 UM 7.2). A word write to the command
    // CIR at A1 = 1 then reaches it on the upper half, where UM table 5-7 has
    // the processor duplicate it; a word read of the restore CIR at A1 = 1 comes
    // back on the upper half too, which is what a sixteen-bit port means.
    // ======================================================================
    base_setup();
    cp.port16 = 1'b1;
    poke_w(CODE + 0, 16'hF200);            // cpGEN
    poke_w(CODE + 2, 16'h2400);
    poke_w(CODE + 4, 16'hF358);            // cpRESTORE (A0)+
    poke_w(CODE + 6, 16'h60FE);
    poke_l(DATA + 0, 32'h1804_0000);
    poke_l(DATA + 4, 32'h1357_9BDF);
    cp.push_resp(16'h8C04);                // CA, D4 to the coprocessor
    cp.push_resp(16'h0802);
    reset_dut();
    dut.u_seq.dreg[4] = 32'h0246_8ACE;
    dut.u_seq.areg[0] = DATA;
    run_until(CODE + 6, 3000, reached);
    check(reached, "MC68881 port: both instructions end");
    check(dut.u_seq.areg[0] === DATA + 32'd8, "MC68881 port: the restore took eight bytes");
    expect_cir(1'b0, R_CMD, 2, 32'h2400, "MC68881 port");
    expect_cir(1'b1, R_RESP, 2, 32'h8C04, "MC68881 port");
    expect_cir(1'b0, R_OPND, 4, 32'h0246_8ACE, "MC68881 port");
    expect_cir(1'b1, R_RESP, 2, 32'h0802, "MC68881 port");
    expect_cir(1'b0, R_REST, 2, 32'h1804, "MC68881 port: restore");
    expect_cir(1'b1, R_REST, 2, 32'h1804, "MC68881 port: the answer, on D31-D16");
    expect_cir(1'b0, R_OPND, 4, 32'h1357_9BDF, "MC68881 port: the state");
    expect_end("MC68881 port");
    cp.port16 = 1'b0;

    if (fails == 0)
      $display("PASS: core_cpif_tb (%0d checks)", checks);
    else
      $display("FAIL: core_cpif_tb (%0d of %0d checks failed)", fails, checks);
    $finish;
  end

endmodule
