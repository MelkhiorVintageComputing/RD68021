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
//
// Figure 5-44 has seven states. Besides the ordinary sequence 0-1-2-3-4-0 this
// covers the re-grant through states 5 and 6 with two masters on a wire-ORed BR,
// 6 back to 3, and single-wire arbitration (0 to 4, BGACK alone) on an idle bus,
// during a cycle and during a read-modify-write.

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
    // Figure 5-44, states 4-5-6-2-3-4-0: the re-grant. "If another BR is
    // still pending after the assertion of BGACK, another BG is asserted
    // within a few clocks", and "the processor does not perform any external
    // bus cycles before it reasserts BG" (UM 5.7.1.3). Two masters on a
    // wire-ORed BR; a request of the processor's own pending throughout, to
    // show it never gets a cycle in.
    // -------------------------------------------------------------------
    begin
      bit rel, held6, held2;
      int unsigned c0, w0;
      realtime tn, ta;
      c0 = as_count;
      rel = 1'b1; held6 = 1'b1; held2 = 1'b1;
      fork
        begin
          @(posedge clk);
          br_drv = 1'b1;                           // master 1
          @(negedge bg_n_o);
          @(posedge clk);
          bgack_drv = 1'b1;                        // master 1 takes the bus,
          // and BR stays asserted: master 2 is now asking.
          @(posedge bg_n_o);                       // state 3
          tn = $realtime;
          w0 = 0;
          while (bg_n_o !== 1'b0 && w0 < 20) begin
            @(posedge clk); #(SNAP); w0 = w0 + 1;
          end
          ta = $realtime;
          $sformat(what, "re-grant: BG asserted again with BGACK still asserted (state 5), after %0.1f clocks",
                   (ta - tn) / CLK_PERIOD);
          check(bg_n_o === 1'b0 && w0 < 6, what);
          $sformat(what, "re-grant: BG negated for at least 1.5 clocks between grants (spec 39, got %0.1f)",
                   (ta - tn) / CLK_PERIOD);
          check((ta - tn) >= 1.5 * CLK_PERIOD, what);
          // State 6: held for as long as master 1 holds BGACK.
          repeat (8) begin
            @(negedge clk); #(SNAP);
            if (bg_n_o !== 1'b0) held6 = 1'b0;
          end
          @(posedge clk);
          bgack_drv = 1'b0;                        // master 1 lets go: state 2
          repeat (6) begin
            @(negedge clk); #(SNAP);
            if (bg_n_o !== 1'b0) held2 = 1'b0;
            if (a_oe !== 1'b0 || as_oe !== 1'b0) rel = 1'b0;
          end
          @(posedge clk);
          bgack_drv = 1'b1;                        // master 2 takes it
          @(posedge clk);
          br_drv = 1'b0;
          repeat (8) @(posedge clk);
          check(bg_n_o === 1'b1, "re-grant: BG negated once the second master acknowledges");
          check(as_count == c0, "re-grant: no processor cycle at any point of the hand-over");
          @(posedge clk);
          bgack_drv = 1'b0;                        // state 4 to state 0
        end
        begin
          // The processor's own request, presented from the first grant on --
          // presented earlier, it would run first: BG is "deferred until the
          // bus cycle has begun".
          @(negedge bg_n_o);
          @(posedge clk);
          op_read(32'h0000_0100, 4, got, cycles);
        end
        begin
          // The bus stays released from the first grant to the end.
          @(posedge bgack_drv);
          @(posedge clk);
          while (bgack_drv || br_drv) begin
            @(negedge clk); #(SNAP);
            if (bgack_drv && (a_oe !== 1'b0 || as_oe !== 1'b0 || rw_oe !== 1'b0))
              rel = 1'b0;
          end
        end
      join
      check(held6, "re-grant: BG held while the old master still asserts BGACK (state 6)");
      check(held2, "re-grant: BG held after the old master lets go, until the new one acknowledges (state 2)");
      check(rel, "re-grant: the bus stays released through the hand-over");
      check(got[31:0] === 32'h10111213, "re-grant: the processor's cycle runs once the bus is returned");
      check(as_count == c0 + 1, "re-grant: ... as one bus cycle");
      $display("  .. re-grant (states 5 and 6) done");
      repeat (6) @(posedge clk);
    end

    // -------------------------------------------------------------------
    // Figure 5-44, 6 to 3: in state 6 the request goes away. G drops, T stays
    // until the old master's BGACK does.
    // -------------------------------------------------------------------
    begin
      bit kept;
      @(posedge clk);
      br_drv = 1'b1;
      @(negedge bg_n_o);
      @(posedge clk);
      bgack_drv = 1'b1;
      @(posedge bg_n_o);
      @(negedge bg_n_o);                          // state 5
      @(posedge clk);
      br_drv = 1'b0;                              // 6 -> 3 -> 4
      repeat (6) @(posedge clk);
      check(bg_n_o === 1'b1, "state 6, BR negated: BG negates (states 3 and 4)");
      kept = (a_oe === 1'b0 && as_oe === 1'b0);
      check(kept, "state 6, BR negated: the bus stays released while BGACK is asserted");
      @(posedge clk);
      bgack_drv = 1'b0;
      repeat (6) @(posedge clk);
      check(bus_granted === 1'b0 && as_oe === 1'b1, "state 4, BGACK negated: the processor drives again");
      $display("  .. 6 -> 3 -> 4 -> 0 done");
    end

    // -------------------------------------------------------------------
    // Single-wire arbitration, figure 5-44's 0 to 4: BGACK alone, with no BR
    // and no BG, places the buses in the high-impedance state.
    // -------------------------------------------------------------------
    begin
      bit no_bg;
      int unsigned c0;
      no_bg = 1'b1;
      c0 = as_count;
      fork
        begin
          @(posedge clk);
          bgack_drv = 1'b1;
          repeat (4) @(posedge clk);
          check(bus_granted === 1'b1 && a_oe === 1'b0 && as_oe === 1'b0 && rw_oe === 1'b0,
                "single-wire, idle bus: BGACK alone releases the bus");
          repeat (6) @(posedge clk);
          check(as_count == c0, "single-wire: a pending request waits for BGACK to negate");
          bgack_drv = 1'b0;
        end
        begin
          wait (bus_granted === 1'b1);
          op_read(32'h0000_0104, 4, got, cycles);
        end
        begin
          while (bgack_drv !== 1'b1) @(posedge clk);
          while (bgack_drv === 1'b1) begin
            @(negedge clk); #(SNAP);
            if (bg_n_o !== 1'b1) no_bg = 1'b0;
          end
        end
      join
      check(no_bg, "single-wire: BG is never asserted");
      check(got[31:0] === 32'h14151617, "single-wire: the request runs once BGACK negates");
      repeat (4) @(posedge clk);

      // ... and during a cycle: the cycle completes, then the bus goes -- "the
      // high-impedance state after the next rising edge following the negation
      // of AS and RMC" (UM 5.7.1.4).
      fork
        begin
          @(negedge as_n_o);
          @(posedge clk);
          bgack_drv = 1'b1;
          @(posedge as_n_o);
          @(posedge clk); #(SNAP);
          check(a_oe === 1'b0 && as_oe === 1'b0,
                "single-wire during a cycle: released at the rising edge after AS negates (UM 5.7.1.4)");
          repeat (4) @(posedge clk);
          bgack_drv = 1'b0;
        end
        op_read(32'h0000_0108, 4, got, cycles);
      join
      check(got[31:0] === 32'h18191A1B && cycles == 1,
            "single-wire during a cycle: the cycle completes with its data");
      repeat (6) @(posedge clk);
    end

    // -------------------------------------------------------------------
    // Single-wire arbitration during a read-modify-write. "The MC68020 does
    // not allow arbitration of the external bus during the read-modify-write
    // sequence", and the release follows "the negation of AS and RMC" (UM
    // 5.7.1.4): the write completes, still locked, and the bus goes after it.
    // (The MC68030 releases between the two -- its UM 7.7.4 has single-wire
    // arbitration apply "to all bus cycles of a read-modify-write sequence";
    // the MC68020's manual has no such sentence.)
    // -------------------------------------------------------------------
    begin
      bit kept, released;
      kept = 1'b1; released = 1'b0;
      s32.mem[12'h180] = 8'h00;
      fork
        begin
          @(negedge as_n_o);
          @(posedge clk);
          bgack_drv = 1'b1;
          while (rmc_n_o === 1'b0) begin
            @(negedge clk); #(SNAP);
            if (rmc_n_o === 1'b0 && (bus_granted !== 1'b0 || rmc_oe !== 1'b1)) kept = 1'b0;
          end
          repeat (3) @(posedge clk); #(SNAP);
          released = (bus_granted === 1'b1 && a_oe === 1'b0 && as_oe === 1'b0);
          repeat (4) @(posedge clk);
          bgack_drv = 1'b0;
        end
        begin
          req_rmc = 1'b1;
          op_read (32'h0000_0180, 1, got, cycles);
          op_write(32'h0000_0180, 1, 40'h80, cycles);
          req_rmc = 1'b0;
          op_read (32'h0000_0F00, 4, got, cycles);
        end
      join
      check(kept, "single-wire during RMC: the bus stays driven while RMC is asserted (UM 5.7.1.4)");
      check(s32.mem[12'h180] === 8'h80, "single-wire during RMC: the locked write completes");
      check(released, "single-wire during RMC: the bus is released once the sequence is over");
      $display("  .. single-wire arbitration done");
      repeat (6) @(posedge clk);
    end

    // -------------------------------------------------------------------
    // HALT on its own -- UM 5.5.3 and figure 5-41. HALT asserted while the
    // bus is idle stops the next cycle from starting: the processor "halts
    // external bus activity at the next bus cycle boundary". Then single-step:
    // "negating and reasserting HALT in accordance with the correct timing
    // requirements provides a single-step (bus cycle to bus cycle)
    // operation". A long word from the 8-bit port is four cycles, so four
    // steps.
    // -------------------------------------------------------------------
    begin
      bit ok_step, quiet;
      int unsigned c0, i;
      @(posedge clk);
      halt_drv = 1'b1;
      repeat (4) @(posedge clk);
      c0 = as_count;
      ok_step = 1'b1;
      quiet = 1'b1;
      fork
        op_read(32'h2000_0100, 4, got, cycles);
        begin
          repeat (10) @(posedge clk);
          if (as_count != c0) quiet = 1'b0;
          for (i = 1; i <= 4; i = i + 1) begin
            // One step: negate HALT, and assert it again once the cycle it
            // lets out has begun.
            halt_drv = 1'b0;
            wait (as_count >= c0 + i);
            @(posedge clk);
            halt_drv = 1'b1;
            repeat (8) @(posedge clk);
            if (as_count != c0 + i) ok_step = 1'b0;
          end
          halt_drv = 1'b0;
        end
      join
      check(quiet, "HALT asserted on an idle bus: no cycle starts (UM 5.5.3)");
      check(ok_step, "single-step: exactly one bus cycle per negation of HALT (figure 5-41)");
      check(got[31:0] === 32'h10111213, "single-step: the operand assembled across four steps");
      repeat (4) @(posedge clk);

      // HALT asserted on an idle bus, with a request pending: no cycle starts,
      // so there is no "internal decision to execute a bus cycle" to defer the
      // grant behind (UM 5.7.1.3), and BR is granted as on any idle bus.
      c0 = as_count;
      @(posedge clk);
      halt_drv = 1'b1;
      repeat (4) @(posedge clk);
      fork
        begin
          repeat (4) @(posedge clk);
          br_drv = 1'b1;
          waited = 0;
          while (bg_n_o !== 1'b0 && waited < 20) begin @(posedge clk); waited = waited + 1; end
          $sformat(what, "halted on an idle bus with a request pending: BR granted (%0d clocks)", waited);
          check(bg_n_o === 1'b0 && waited <= 4, what);
          check(as_count == c0, "halted on an idle bus: the pending request did not start");
          @(posedge clk);
          br_drv = 1'b0;
          repeat (4) @(posedge clk);
          halt_drv = 1'b0;
        end
        op_read(32'h0000_0114, 4, got, cycles);
      join
      check(got[31:0] === 32'h24252627, "halted on an idle bus: the request runs once HALT negates");
      check(as_count == c0 + 1, "halted on an idle bus: as one cycle");
      $display("  .. HALT on an idle bus done");
      repeat (6) @(posedge clk);
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
