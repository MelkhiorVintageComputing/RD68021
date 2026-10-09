// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68021

// RD68021 -- the RESET pin resets the processor: UM 5.8 and 6.1.1.
//
// `rst_n` is the power-on initialisation, which is not an MC68020 pin
// (doc/pinout.md); the RESET pin is the architectural reset, and this is the
// testbench for it, at the level of the whole processor. Ported from RD68031.
//
//   1. A program sets every register a reset spares, and some it does not,
//      and is reset in the middle of a loop: during the reset period the bus
//      three-states; after it, the first bus cycles read the initial
//      interrupt stack pointer from $0 and the program counter from $4, in
//      supervisor program space (UM 5.8, 6.1.1); S set, T1 T0 and M clear,
//      the mask at 7, VBR zero, CACR's E and F clear, the instruction cache
//      invalidated -- by running code the cache held before the reset, and
//      changed while it was held, with the cache enabled again. What UM 6.1.1
//      does not name keeps its value: D0-D7, A0-A6, USP, MSP, SFC, DFC and
//      CAAR.
//   2. "Only an external RESET can restart a processor halted by a double bus
//      fault" (UM 6.1.2): a double bus fault, HALT asserted, then the pin, and
//      the processor runs again.
//   3. A stopped processor (PRM 6 STOP) is restarted by the pin.
//   4. Reset exception processing is a double-bus-fault window (UM 6.1.2): a
//      bus error on the vector read, an odd initial program counter, and a
//      bus error on the first prefetch each halt it.
//   5. The RESET instruction drives the pin and reads its own pulse back, and
//      does not reset the processor (UM 5.8, "the internal registers of the
//      processor are unaffected"); a RESET from outside that outlasts the
//      pulse by eight clocks does.

`timescale 1ns / 1ps

module core_reset_tb;

`include "rd68021_core_harness.svh"

  localparam logic [31:0] ISP0  = 32'h0000_1000;
  localparam logic [31:0] ISP1  = 32'h0000_1800;
  localparam logic [31:0] CODE  = 32'h0000_0400;
  localparam logic [31:0] LOOP  = CODE + 32'h92;
  localparam logic [31:0] CODE2 = 32'h0000_0600;
  localparam logic [31:0] CODE3 = 32'h0000_0700;
  localparam logic [31:0] CODE4 = 32'h0000_0780;
  localparam logic [31:0] CODE5 = 32'h0000_0800;
  localparam logic [31:0] SPIN  = 32'h0000_0900;
  localparam logic [31:0] SPIN2 = 32'h0000_0910;
  localparam logic [31:0] BAD   = 32'h0000_E000;   // a region that answers BERR

  bit          reached;
  logic [31:0] d0_at_reset;
  string       what;
  int unsigned n;

  // The bus cycles after a reset, as a device sees them.
  bit          rec_on;
  int unsigned nrec;
  logic [31:0] rec_a  [0:3];
  logic  [2:0] rec_fc [0:3];
  logic        rec_rw [0:3];
  logic  [1:0] rec_siz[0:3];
  initial begin rec_on = 1'b0; nrec = 0; end
  always @(negedge as_n_o)
    if (rst_n && rec_on && nrec < 4) begin
      rec_a[nrec]   = a_o;
      rec_fc[nrec]  = fc_o;
      rec_rw[nrec]  = rw_o;
      rec_siz[nrec] = siz_o;
      nrec = nrec + 1;
    end

  // AS falling edges, for the tests whose subject is that there are none.
  int unsigned starts;
  initial starts = 0;
  always @(negedge as_n_o) if (rst_n) starts = starts + 1;

  // The RESET pin, low from outside for `clocks` clocks. Changed on falling
  // edges, as every input the design samples.
  task automatic pin_reset(input int clocks);
    @(negedge clk);
    reset_in_n = 1'b0;
    repeat (clocks) @(posedge clk);
    @(negedge clk);
    reset_in_n = 1'b1;
  endtask

  task automatic base_setup();
    int unsigned v;
    for (v = 0; v < 256; v = v + 1)
      poke_l(v * 4, 32'h0000_9000);   // an unexpected vector spins at $9000
    poke_w(32'h0000_9000, 16'h60FE);  // BRA *
    poke_l(32'h0000_0000, ISP0);
    poke_l(32'h0000_0004, CODE);
    poke_w(SPIN,  16'h60FE);
    poke_w(SPIN2, 16'h60FE);
  endtask

  // The vector a reset will read next, and the test that the processor got
  // there through reset exception processing and nothing else.
  task automatic expect_boot(input logic [31:0] isp, input logic [31:0] pc,
                             input string when);
    run_until(pc, 4000, reached);
    check(reached, {when, ": the processor runs from the reset vector's program counter"});
    check(nrec >= 2 && rec_a[0] === 32'h0 && rec_fc[0] === 3'd6 && rec_rw[0] === 1'b1
          && rec_siz[0] === 2'b00,
          {when, ": the first cycle reads the initial ISP, a long word at $0 in supervisor program space -- UM 5.8"});
    check(nrec >= 2 && rec_a[1] === 32'h4 && rec_fc[1] === 3'd6 && rec_rw[1] === 1'b1,
          {when, ": the second reads the initial PC at $4 -- UM 6.1.1"});
    check(dut.u_seq.sr_q === 16'h2700,
          {when, ": SR $2700 -- T1 T0 clear, S set, M clear, mask 7 (UM 6.1.1)"});
    check(dut.u_seq.isp_q === isp, {when, ": ISP from $0 -- UM 6.1.1"});
  endtask

  initial begin
    $display("core_reset_tb: the RESET pin -- UM 5.8, 6.1.1");

    // ======================================================================
    // 1. A reset in the middle of a program.
    // ======================================================================
    base_setup();
    poke_w(CODE + 32'h000, 16'h223C);  // move.l #0x11111111,%d1
    poke_w(CODE + 32'h002, 16'h1111);
    poke_w(CODE + 32'h004, 16'h1111);
    poke_w(CODE + 32'h006, 16'h243C);  // move.l #0x22222222,%d2
    poke_w(CODE + 32'h008, 16'h2222);
    poke_w(CODE + 32'h00A, 16'h2222);
    poke_w(CODE + 32'h00C, 16'h263C);  // move.l #0x33333333,%d3
    poke_w(CODE + 32'h00E, 16'h3333);
    poke_w(CODE + 32'h010, 16'h3333);
    poke_w(CODE + 32'h012, 16'h283C);  // move.l #0x44444444,%d4
    poke_w(CODE + 32'h014, 16'h4444);
    poke_w(CODE + 32'h016, 16'h4444);
    poke_w(CODE + 32'h018, 16'h2A3C);  // move.l #0x55555555,%d5
    poke_w(CODE + 32'h01A, 16'h5555);
    poke_w(CODE + 32'h01C, 16'h5555);
    poke_w(CODE + 32'h01E, 16'h2C3C);  // move.l #0x66666666,%d6
    poke_w(CODE + 32'h020, 16'h6666);
    poke_w(CODE + 32'h022, 16'h6666);
    poke_w(CODE + 32'h024, 16'h2E3C);  // move.l #0x77777777,%d7
    poke_w(CODE + 32'h026, 16'h7777);
    poke_w(CODE + 32'h028, 16'h7777);
    poke_w(CODE + 32'h02A, 16'h43F9);  // lea 0xA1A1A1A0,%a1
    poke_w(CODE + 32'h02C, 16'hA1A1);
    poke_w(CODE + 32'h02E, 16'hA1A0);
    poke_w(CODE + 32'h030, 16'h45F9);  // lea 0xA2A2A2A0,%a2
    poke_w(CODE + 32'h032, 16'hA2A2);
    poke_w(CODE + 32'h034, 16'hA2A0);
    poke_w(CODE + 32'h036, 16'h47F9);  // lea 0xA3A3A3A0,%a3
    poke_w(CODE + 32'h038, 16'hA3A3);
    poke_w(CODE + 32'h03A, 16'hA3A0);
    poke_w(CODE + 32'h03C, 16'h49F9);  // lea 0xA4A4A4A0,%a4
    poke_w(CODE + 32'h03E, 16'hA4A4);
    poke_w(CODE + 32'h040, 16'hA4A0);
    poke_w(CODE + 32'h042, 16'h4BF9);  // lea 0xA5A5A5A0,%a5
    poke_w(CODE + 32'h044, 16'hA5A5);
    poke_w(CODE + 32'h046, 16'hA5A0);
    poke_w(CODE + 32'h048, 16'h4DF9);  // lea 0xA6A6A6A0,%a6
    poke_w(CODE + 32'h04A, 16'hA6A6);
    poke_w(CODE + 32'h04C, 16'hA6A0);
    poke_w(CODE + 32'h04E, 16'h41F8);  // lea 0x3000,%a0
    poke_w(CODE + 32'h050, 16'h3000);
    poke_w(CODE + 32'h052, 16'h4E60);  // move.l %a0,%usp
    poke_w(CODE + 32'h054, 16'h41F8);  // lea 0x2000,%a0
    poke_w(CODE + 32'h056, 16'h2000);
    poke_w(CODE + 32'h058, 16'h4E7B);  // movec %a0,%msp
    poke_w(CODE + 32'h05A, 16'h8803);
    poke_w(CODE + 32'h05C, 16'h7005);  // moveq #5,%d0
    poke_w(CODE + 32'h05E, 16'h4E7B);  // movec %d0,%sfc
    poke_w(CODE + 32'h060, 16'h0000);
    poke_w(CODE + 32'h062, 16'h7006);  // moveq #6,%d0
    poke_w(CODE + 32'h064, 16'h4E7B);  // movec %d0,%dfc
    poke_w(CODE + 32'h066, 16'h0001);
    poke_w(CODE + 32'h068, 16'h203C);  // move.l #0xCAFEBAB0,%d0
    poke_w(CODE + 32'h06A, 16'hCAFE);
    poke_w(CODE + 32'h06C, 16'hBAB0);
    poke_w(CODE + 32'h06E, 16'h4E7B);  // movec %d0,%caar
    poke_w(CODE + 32'h070, 16'h0802);
    poke_w(CODE + 32'h072, 16'h203C);  // move.l #0x1,%d0 -- E: the loop is cached
    poke_w(CODE + 32'h074, 16'h0000);
    poke_w(CODE + 32'h076, 16'h0001);
    poke_w(CODE + 32'h078, 16'h4E7B);  // movec %d0,%cacr
    poke_w(CODE + 32'h07A, 16'h0002);
    poke_w(CODE + 32'h07C, 16'h203C);  // move.l #0x8000,%d0
    poke_w(CODE + 32'h07E, 16'h0000);
    poke_w(CODE + 32'h080, 16'h8000);
    poke_w(CODE + 32'h082, 16'h4E7B);  // movec %d0,%vbr
    poke_w(CODE + 32'h084, 16'h0801);
    poke_w(CODE + 32'h086, 16'h41F9);  // lea 0xA0A0A0A0,%a0
    poke_w(CODE + 32'h088, 16'hA0A0);
    poke_w(CODE + 32'h08A, 16'hA0A0);
    poke_w(CODE + 32'h08C, 16'h46FC);  // move.w #0x3700,%sr -- S, M, mask 7
    poke_w(CODE + 32'h08E, 16'h3700);
    poke_w(CODE + 32'h090, 16'h7000);  // moveq #0,%d0
    poke_w(CODE + 32'h092, 16'h5280);  // loop: addq.l #1,%d0
    poke_w(CODE + 32'h094, 16'h60FC);  // bra.s loop
    // After the reset: the cache on again, and back to the loop.
    poke_w(CODE2 + 32'h000, 16'h7001);  // moveq #1,%d0
    poke_w(CODE2 + 32'h002, 16'h4E7B);  // movec %d0,%cacr
    poke_w(CODE2 + 32'h004, 16'h0002);
    poke_w(CODE2 + 32'h006, 16'h4EF8);  // jmp LOOP
    poke_w(CODE2 + 32'h008, LOOP[15:0]);
    // A pending interrupt, which the reset's mask of 7 holds off -- UM 6.1.1
    // step 3 -- so that the first thing the processor does is the program.
    ipl_n_i = ~3'd5;
    reset_dut();
    run_until(LOOP + 2, 4000, reached);
    check(reached, "1: the program reaches its loop");
    repeat (300) @(negedge clk);
    check(dut.u_seq.sr_q === 16'h3700 && dut.u_seq.vbr_q === 32'h8000
          && dut.u_seq.cacr_q === 32'h1 && dut.u_seq.msp_q === 32'h2000,
          "1: before the reset: SR $3700, VBR $8000, CACR $1, MSP $2000");
    // The loop in the cache is changed in memory while the reset is held.
    poke_l(32'h0, ISP1);
    poke_l(32'h4, CODE2);
    poke_w(LOOP,     16'h7C5A);          // moveq #0x5A,%d6
    poke_w(LOOP + 2, 16'h60FE);          // bra.s .
    rec_on = 1'b0;
    fork
      pin_reset(20);
      begin
        // Two falling-edge ranks of synchroniser and a rising edge, then one
        // more clock for the retiring microword to finish committing.
        @(posedge dut.crst);
        @(posedge clk);
        d0_at_reset = dut.u_seq.dreg[0];
        repeat (4) @(posedge clk);
        #(CLK_PERIOD / 8.0);
        check(a_oe === 1'b0 && fc_oe === 1'b0 && siz_oe === 1'b0 && d_oe === 1'b0
              && as_oe === 1'b0 && ds_oe === 1'b0 && rw_oe === 1'b0 && rmc_oe === 1'b0
              && dben_oe === 1'b0,
              "1: during the reset period the entire bus three-states -- UM 5.8");
        check(ecs_n_o === 1'b1 && ocs_n_o === 1'b1 && ipend_n_o === 1'b1,
              "1: ... and ECS, OCS and IPEND, which are not three-stated, are inactive");
        n = starts;
        repeat (10) @(posedge clk);
        check(starts == n, "1: no bus cycle while the reset is held");
        // The working registers the pin does not reset -- rd68021_seq's crst
        // arm -- given junk while it is held: reset exception processing and
        // the program after it must not read any of them before writing it.
        dut.u_seq.t_q[0] = 32'hDEAD_0000;
        dut.u_seq.t_q[1] = 32'hDEAD_0001;
        dut.u_seq.t_q[2] = 32'hDEAD_0002;
        dut.u_seq.t_q[3] = 32'hDEAD_0003;
        dut.u_seq.xw_q       = 16'hBEEF;
        dut.u_seq.ea_q       = 32'hDEAD_00EA;
        dut.u_seq.link_q     = '1;
        dut.u_seq.rupc_q     = '1;
        dut.u_seq.cprim_q    = 16'hFFFF;
        dut.u_seq.pc_prev_q  = 32'hDEAD_0FFC;
        dut.u_seq.rst_addr_q = 32'hDEAD_00AD;
        dut.u_seq.rst_data_q = 32'hDEAD_00DA;
        dut.u_seq.rst_bytes_q = 3'd4;
        @(negedge dut.crst);
        nrec = 0;
        rec_on = 1'b1;
      end
    join
    expect_boot(ISP1, CODE2, "1");
    rec_on = 1'b0;
    // Nothing of CODE2 has run: what the reset spared is as the program left it.
    check(dut.u_seq.dreg[0] === d0_at_reset && d0_at_reset > 32'd0,
          $sformatf("1: D0 is the count it had reached, %0d", d0_at_reset));
    check(dut.u_seq.dreg[1] === 32'h1111_1111 && dut.u_seq.dreg[2] === 32'h2222_2222
          && dut.u_seq.dreg[3] === 32'h3333_3333 && dut.u_seq.dreg[4] === 32'h4444_4444
          && dut.u_seq.dreg[5] === 32'h5555_5555 && dut.u_seq.dreg[6] === 32'h6666_6666
          && dut.u_seq.dreg[7] === 32'h7777_7777,
          "1: D1-D7 kept -- UM 6.1.1 does not name them");
    check(dut.u_seq.areg[0] === 32'hA0A0_A0A0 && dut.u_seq.areg[1] === 32'hA1A1_A1A0
          && dut.u_seq.areg[2] === 32'hA2A2_A2A0 && dut.u_seq.areg[3] === 32'hA3A3_A3A0
          && dut.u_seq.areg[4] === 32'hA4A4_A4A0 && dut.u_seq.areg[5] === 32'hA5A5_A5A0
          && dut.u_seq.areg[6] === 32'hA6A6_A6A0,
          "1: A0-A6 kept");
    check(dut.u_seq.usp_q === 32'h3000 && dut.u_seq.msp_q === 32'h2000,
          "1: USP and MSP kept; the reset loaded ISP");
    check(dut.u_seq.sfc_q === 3'd5 && dut.u_seq.dfc_q === 3'd6
          && dut.u_seq.caar_q === 32'hCAFE_BAB0,
          "1: SFC, DFC and CAAR kept");
    check(dut.u_seq.vbr_q === 32'h0, "1: VBR zero -- UM 6.1.1");
    check(dut.u_seq.cacr_q === 32'h0, "1: CACR's enable bit clear -- UM 4.2");
    check(dut.u_seq.trace_mode_q === 2'b00 && !dut.u_seq.dbf_q && !dut.u_seq.stopped_q,
          "1: no trace, not halted, not stopped");
    // UM 4.2: the cache was invalidated. The loop's two words were in
    // it, with the cache enabled, before the reset; they were changed in
    // memory while it was held; with the cache enabled again, the new words
    // run. A cache that kept its entries would go on counting in D0.
    run_until(LOOP + 2, 2000, reached);
    repeat (40) @(negedge clk);
    check(reached && dut.u_seq.dreg[6] === 32'h0000_005A && dut.u_seq.dreg[0] === 32'd1,
          "1: the instruction cache was invalidated -- UM 4.2");
    check(dut.u_seq.cacr_q === 32'h1, "1: and is enabled again by the program");
    check(dut.u_seq.sr_q[10:8] === 3'd7 && ipend_n_o === 1'b1,
          "1: the level-5 request stays masked -- UM 6.1.1");
    ipl_n_i = 3'b111;

    // ======================================================================
    // 2. A double bus fault, and the RESET pin that restarts it.
    // ======================================================================
    poke_w(CODE3 + 32'h000, 16'h4FF9);  // lea 0xF000,%sp
    poke_w(CODE3 + 32'h002, 16'h0000);
    poke_w(CODE3 + 32'h004, 16'hF000);
    poke_w(CODE3 + 32'h006, 16'h4A57);  // tst.w (%sp) -- a bus error...
    poke_w(CODE3 + 32'h008, 16'h60FE);  // bra.s .
    poke_l(32'h4, CODE3);
    berr_base = BAD;
    berr_mask = 32'hFFFF_E000;          // $E000-$FFFF
    berr_en   = 1'b1;
    pin_reset(12);
    // ... whose frame goes onto a stack in the same region: UM 6.1.2.
    n = 0;
    while (!dut.u_seq.dbf_q && n < 4000) begin @(negedge clk); n = n + 1; end
    check(dut.u_seq.dbf_q === 1'b1, "2: the bus error's own stacking faults: a double bus fault");
    n = starts;
    repeat (60) @(posedge clk);
    check(halt_n_oe === 1'b1 && starts == n,
          "2: halted -- HALT asserted, no bus cycles (UM 5.5.4)");
    berr_en = 1'b0;
    poke_l(32'h4, SPIN);
    nrec = 0;
    rec_on = 1'b0;
    fork
      pin_reset(12);
      begin @(negedge dut.crst); nrec = 0; rec_on = 1'b1; end
    join
    expect_boot(ISP1, SPIN, "2: RESET after the double bus fault");
    rec_on = 1'b0;
    check(!dut.u_seq.dbf_q && halt_n_oe === 1'b0,
          "2: \"only an external RESET can restart a processor halted by a double bus fault\" -- UM 6.1.2");

    // ======================================================================
    // 3. STOP, and the RESET pin.
    // ======================================================================
    poke_w(CODE4 + 32'h000, 16'h4E72);  // stop #0x2700
    poke_w(CODE4 + 32'h002, 16'h2700);
    poke_w(CODE4 + 32'h004, 16'h60FE);  // bra.s .
    poke_l(32'h4, CODE4);
    pin_reset(12);
    n = 0;
    while (!dut.u_seq.stopped_q && n < 4000) begin @(negedge clk); n = n + 1; end
    check(dut.u_seq.stopped_q === 1'b1, "3: STOP stops the processor");
    poke_l(32'h4, SPIN2);
    fork
      pin_reset(12);
      begin @(negedge dut.crst); nrec = 0; rec_on = 1'b1; end
    join
    expect_boot(ISP1, SPIN2, "3: RESET while stopped");
    rec_on = 1'b0;

    // ======================================================================
    // 4. Faults during reset exception processing: each one a double bus
    // fault, HALT asserted.
    // ======================================================================
    for (int c = 0; c < 3; c++) begin
      case (c)
        0: begin   // a bus error on the vector read itself
             berr_base = 32'h0; berr_mask = 32'hFFFF_FFF8; berr_en = 1'b1;
             what = "a bus error reading the reset vector";
           end
        1: begin   // an odd initial program counter: an address error
             berr_en = 1'b0; poke_l(32'h4, SPIN + 32'd1);
             what = "an odd initial program counter (an address error)";
           end
        default: begin   // the first prefetch is refused
             poke_l(32'h4, BAD); berr_base = BAD; berr_mask = 32'hFFFF_E000;
             berr_en = 1'b1;
             what = "a bus error on the first prefetch";
           end
      endcase
      pin_reset(12);
      n = 0;
      while (!dut.u_seq.dbf_q && n < 400) begin @(negedge clk); n = n + 1; end
      repeat (20) @(posedge clk);
      check(dut.u_seq.dbf_q === 1'b1 && halt_n_oe === 1'b1,
            {"4: ", what, " is a double bus fault -- UM 6.1.2"});
    end
    berr_en = 1'b0;
    poke_l(32'h4, SPIN);
    pin_reset(12);
    run_until(SPIN, 4000, reached);
    check(reached && !dut.u_seq.dbf_q, "4: and a RESET with the vector repaired boots");

    // ======================================================================
    // 5. The RESET instruction: its own pulse resets nothing; one from
    // outside that outlasts it by eight clocks resets the processor.
    // ======================================================================
    poke_w(CODE5 + 32'h000, 16'h7242);  // moveq #0x42,%d1
    poke_w(CODE5 + 32'h002, 16'h4E70);  // reset
    poke_w(CODE5 + 32'h004, 16'h7443);  // moveq #0x43,%d2
    poke_w(CODE5 + 32'h006, 16'h60FE);  // bra.s .
    for (int c = 0; c < 3; c++) begin
      int unsigned past;
      bit crst_seen;
      past = (c == 0) ? 0 : (c == 1) ? 2 : 10;
      poke_l(32'h4, CODE5);
      pin_reset(12);
      run_until(CODE5 + 32'd2, 4000, reached);
      poke_l(32'h4, SPIN2);
      crst_seen = 1'b0;
      fork
        begin
          @(posedge reset_n_oe);
          if (c != 0) begin
            repeat (100) @(posedge clk);
            @(negedge clk);
            reset_in_n = 1'b0;
          end
          @(negedge reset_n_oe);
          repeat (past) @(posedge clk);
          @(negedge clk);
          reset_in_n = 1'b1;
        end
        begin
          n = 0;
          while (n < 700) begin
            @(posedge clk);
            if (dut.crst === 1'b1) crst_seen = 1'b1;
            n = n + 1;
          end
        end
      join
      run_until(CODE5 + 32'd6, 200, reached);
      if (past < 8) begin
        check(!crst_seen && reached && dut.u_seq.dreg[2][7:0] === 8'h43
              && dut.u_seq.sr_q === 16'h2700,
              $sformatf("5: RESET from outside ending %0d clocks after the instruction's pulse: not a reset; the next instruction runs -- UM 5.8",
                        past));
      end else begin
        run_until(SPIN2, 4000, reached);
        check(crst_seen && reached,
              "5: RESET from outside outlasting the pulse by ten clocks resets the processor -- UM 5.8");
      end
      dut.u_seq.dreg[2] = 32'd0;
    end

    if (pipe_fails != 0)
      $display("  FAIL: the pipe invariant broke %0d times", pipe_fails);
    $display("core_reset_tb: %0d checks, %0d failed", checks, fails);
    if (fails == 0 && pipe_fails == 0) $display("PASS: core_reset_tb");
    else                               $display("FAIL: core_reset_tb");
    $finish;
  end

  initial begin
    #50_000_000;
    $display("FAIL: core_reset_tb timed out");
    $finish;
  end

endmodule
