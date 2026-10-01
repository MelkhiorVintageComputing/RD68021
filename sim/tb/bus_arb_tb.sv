// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68021

// RD68021 -- bus arbitration: UM 5.7.1 and the state machine of 5.7.1.4.
//
// The protocol, in the manual's own three steps:
//
//   1. An external device asserts BR.
//   2. The processor asserts BG to indicate that the bus will become available
//      at the end of the current bus cycle.
//   3. The external device asserts BGACK to indicate that it has assumed bus
//      mastership.
//
// and the two rules that are easy to get wrong:
//
//   - "The BG output will not be asserted while RMC is asserted" (the note under
//     figure 5-44). For the duration of a read-modify-write the BR input is
//     ignored entirely.
//   - "If T is true, the address, data, and control buses are placed in the
//     high-impedance state after the next rising edge following the negation of
//     AS and RMC" -- so the release waits for the cycle to finish, and a cycle
//     must never begin on an edge where the bus is about to go away. The harness
//     watches that one continuously, for every testbench, as drive_violations.

`timescale 1ns / 1ps

module bus_arb_tb;

`include "rd68021_bus_harness.svh"

  logic [39:0] got;
  int unsigned cycles;
  int unsigned t;
  int unsigned a0;
  int unsigned waited;
  string       what;
  bit          saw_bg_during_rmc;
  bit          saw_rmc;
  bit          rmc_watch;

  initial begin
    $display("bus_arb_tb: UM 5.7.1 bus arbitration");
    saw_bg_during_rmc = 1'b0;
    saw_rmc           = 1'b0;
    rmc_watch         = 1'b1;
    reset_dut();
    for (t = 0; t < 4096; t = t + 1) begin
      s32.mem[t] = 8'h10 + t[7:0];
      s16.mem[t] = 8'h10 + t[7:0];
      s8.mem[t]  = 8'h10 + t[7:0];
      sw.mem[t]  = 8'h10 + t[7:0];
    end

    // -------------------------------------------------------------------
    // The bus is idle. BR alone must produce BG.
    // -------------------------------------------------------------------
    check(bg_n_o === 1'b1, "idle: BG is negated with no request");
    check(a_oe === 1'b0 || a_oe === 1'b1, "idle: the address enable is defined");

    @(posedge clk);
    br_drv = 1'b1;
    waited = 0;
    while (bg_n_o !== 1'b0 && waited < 20) begin
      @(posedge clk);
      waited = waited + 1;
    end
    $sformat(what, "BR asserted: BG follows within %0d clocks", waited);
    check(bg_n_o === 1'b0, what);
    $display("  .. BG granted");

    // -------------------------------------------------------------------
    // BGACK: the external device takes the bus. Everything the processor drives
    // must go high impedance -- address, data, FC, SIZ, RMC, AS, DS, R/W, DBEN.
    // -------------------------------------------------------------------
    @(posedge clk);
    bgack_drv = 1'b1;
    @(posedge clk);
    br_drv = 1'b0;
    repeat (4) @(posedge clk);

    check(bus_granted === 1'b1, "BGACK asserted: the core reports the bus relinquished");
    check(a_oe    === 1'b0, "granted: the address bus is released");
    check(fc_oe   === 1'b0, "granted: the function codes are released");
    check(siz_oe  === 1'b0, "granted: SIZ is released");
    check(rmc_oe  === 1'b0, "granted: RMC is released");
    check(as_oe   === 1'b0, "granted: AS is released");
    check(ds_oe   === 1'b0, "granted: DS is released");
    check(rw_oe   === 1'b0, "granted: R/W is released");
    check(dben_oe === 1'b0, "granted: DBEN is released");
    check(d_oe    === 1'b0, "granted: the data bus is released");
    check(bg_n_o  === 1'b1, "granted: BG is negated once BGACK is asserted and BR is not");
    $display("  .. relinquish checks done");

    // A request made while another master holds the bus must not start a cycle.
    a0 = as_count;
    pending   = 1'b1;
    req_kind  = 3'd0;
    req_addr  = 32'h0000_0100;
    req_bytes = 3'd4;
    repeat (8) @(posedge clk);
    check(as_count == a0, "granted: no bus cycle starts while the bus is held");
    check(a_oe === 1'b0,  "granted: still released with a request pending");
    $display("  .. pending-while-granted done");

    // -------------------------------------------------------------------
    // Returning the bus. "When A is negated, the arbiter returns to the original
    // state, state 0, and negates signal T."
    // -------------------------------------------------------------------
    @(posedge clk);
    bgack_drv = 1'b0;
    @(posedge req_ack);
    pending = 1'b0;
    check(req_rdata[31:0] === 32'h10111213,
          "the pending cycle runs once the bus is returned");
    check(bus_granted === 1'b0, "bus returned: the core drives again");
    $display("  .. bus returned");
    @(negedge clk);

    // -------------------------------------------------------------------
    // Arbitration during a cycle: BR asserted mid-cycle must not disturb it, and
    // the grant must wait for the cycle to finish.
    // -------------------------------------------------------------------
    fork
      begin
        @(negedge as_n_o);       // the cycle has begun
        @(posedge clk);
        br_drv = 1'b1;
        @(posedge as_n_o);       // AS negated: the cycle is over
        check(1'b1, "BR during a cycle: the cycle completed");
      end
      op_read(32'h0000_0120, 4, got, cycles);
    join
    check(got[31:0] === 32'h30313233, "BR during a cycle: the data is intact");
    check(cycles == 1,                "BR during a cycle: still one bus cycle");
    $display("  .. BR during a cycle done");

    @(posedge clk);
    br_drv    = 1'b0;
    bgack_drv = 1'b0;
    repeat (6) @(posedge clk);

    // -------------------------------------------------------------------
    // The RMC inhibit. "The BG output will not be asserted while RMC is
    // asserted"; "for the duration of this sequence, the MC68020 ignores the BR
    // input."
    //
    // A locked sequence is a run of ordinary cycles with req_rmc raised on each
    // of them -- there is no RMW cycle kind on this part (UM 5.5.2).
    // -------------------------------------------------------------------
    begin
      fork
        // Watch BG for as long as the locked sequence runs. Both branches end by
        // themselves: a join_any with a disable would kill an operand task in
        // mid-flight and leave its request asserted.
        begin
          while (rmc_watch) begin
            @(posedge clk);
            if (rmc_n_o === 1'b0 && bg_n_o === 1'b0) saw_bg_during_rmc = 1'b1;
            if (rmc_n_o === 1'b0) saw_rmc = 1'b1;
          end
        end
        begin
          @(posedge clk);
          br_drv  = 1'b1;          // ask for the bus throughout
          req_rmc = 1'b1;
          op_read (32'h0000_0140, 4, got, cycles);
          op_write(32'h0000_0140, 4, 40'h00_CAFEF00D, cycles);
          req_rmc = 1'b0;
          // One more, unlocked, so RMC negates at the start of it -- UM 5.1.1,
          // "RMC is guaranteed to be negated before the end of state 0 for a bus
          // cycle following a read-modify-write operation".
          op_read (32'h0000_0150, 4, got, cycles);
          rmc_watch = 1'b0;
        end
      join

      check(saw_rmc,
            "the locked sequence actually asserted RMC");
      check(!saw_bg_during_rmc,
            "RMC asserted: BG is never asserted, even with BR held throughout");
      check({s32.mem[32'h140], s32.mem[32'h141], s32.mem[32'h142], s32.mem[32'h143]}
            === 32'hCAFEF00D, "the locked sequence wrote its operand");

      // With RMC gone, the same standing BR is granted.
      waited = 0;
      while (bg_n_o !== 1'b0 && waited < 20) begin
        @(posedge clk);
        waited = waited + 1;
      end
      $sformat(what, "RMC negated: the held BR is granted within %0d clocks", waited);
      check(bg_n_o === 1'b0, what);
      $display("  .. RMC inhibit done");
      @(posedge clk);
      br_drv = 1'b0;
      repeat (6) @(posedge clk);
    end

    // -------------------------------------------------------------------
    // Relinquish and retry: BERR, HALT and BR together. UM 5.5.2.
    // -------------------------------------------------------------------
    begin
      a0 = as_count;
      fork
        begin
          assert_at_n(1'b1, 1'b1);
          br_drv = 1'b1;
          repeat (2) @(posedge clk);
          berr_drv = 1'b0;
          halt_drv = 1'b0;
          repeat (4) @(posedge clk);
          br_drv = 1'b0;
        end
        op_read(32'h0000_0160, 4, got, cycles);
      join
      check(got[31:0] === 32'h70717273,
            "relinquish and retry: the operand completes with the right data");
      check(cycles == 2, "relinquish and retry: the cycle is rerun once");
      $display("  .. relinquish and retry done");
    end

    // -------------------------------------------------------------------
    // BR at every phase of a multi-cycle operand.
    //
    // This is the one that catches the MC68010 project's arbitration bug. A
    // four-byte read on an 8-bit port is four bus cycles (Table 5-6), so a bus
    // request arriving part-way through has to be granted at the end of a cycle
    // and the rest of the operand resumed afterwards. If the decision to start a
    // cycle is taken from the arbiter's current state while the bus release
    // follows its next one, then at exactly one phase a fifth cycle begins on the
    // edge the bus goes away: it drives nothing, no slave answers, and the
    // operand hangs or returns the wrong bytes.
    //
    // Sweeping the phase is what makes that reachable -- a single fixed delay
    // misses it, which a first attempt at this test duly did.
    // -------------------------------------------------------------------
    begin
      int unsigned ph;
      for (ph = 0; ph < 16; ph = ph + 1) begin
        fork
          begin
            repeat (ph) @(posedge clk);
            br_drv = 1'b1;
            repeat (6) @(posedge clk);
            br_drv = 1'b0;
          end
          op_read(32'h2000_0100, 4, got, cycles);
        join
        $sformat(what,
                 "BR at phase %0d of a four-cycle operand: data (got %08h)",
                 ph, got[31:0]);
        check(got[31:0] === 32'h10111213, what);
        $sformat(what, "BR at phase %0d: still four bus cycles (got %0d)",
                 ph, cycles);
        check(cycles == 4, what);
        @(posedge clk);
        br_drv    = 1'b0;
        bgack_drv = 1'b0;
        repeat (4) @(posedge clk);
      end
      $display("  .. BR phase sweep done");
    end

    // -------------------------------------------------------------------
    // Double bus fault: UM 5.5.4, "the processor halts and asserts HALT".
    // -------------------------------------------------------------------
    check(halt_n_oe === 1'b0, "no double bus fault: HALT is not driven");
    @(posedge clk);
    dbf_drv = 1'b1;
    @(posedge clk);
    check(halt_n_oe === 1'b1, "double bus fault: HALT is driven");
    check(halt_n_o  === 1'b0, "double bus fault: HALT is open drain, pulled low");
    @(posedge clk);
    dbf_drv = 1'b0;

    $display("bus_arb_tb: %0d checks, %0d failures, %0d drive violations",
             checks, fails, drive_violations);
    if (fails == 0 && drive_violations == 0) $display("PASS: bus_arb_tb");
    else                                     $display("FAIL: bus_arb_tb");
    $finish;
  end

  initial begin
    #1_000_000;
    $display("FAIL: bus_arb_tb timed out");
    $finish;
  end

endmodule
