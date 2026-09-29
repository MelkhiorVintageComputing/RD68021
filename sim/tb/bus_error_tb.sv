// RD68021 -- bus exception control: UM Table 5-8, all six cases.
//
// The table indexes two samples by "the number of the current even bus state":
// n is S2, one clock after AS asserts, and n+2 is S4. Every case below asserts
// its signals on the rising edge of exactly those states, which is also what
// UM 5.5 asks an external device to do so that specification 47A and 47B are met
// for the same falling edge.
//
//   1  DSACK, no BERR, no HALT                  normal cycle terminate and continue
//   2  HALT at or before DSACK                  normal terminate and halt
//   3  BERR in lieu of / at / before DSACK      terminate and take a bus error
//   4  BERR one state pair after DSACK          the same, deferred
//   5  BERR and HALT in lieu of / before        terminate and retry when HALT negated
//   6  BERR and HALT after DSACK                the same, deferred
//
// Cases 4 and 6 are the ones that earn their keep. On the MC68010 project the
// equivalent late assertion was detected and never delivered.

`timescale 1ns / 1ps

module bus_error_tb;

`include "rd68021_bus_harness.svh"

  logic [39:0] got;
  int unsigned cycles;
  int unsigned t;
  int unsigned a0;
  string       what;

  initial begin
    $display("bus_error_tb: UM Table 5-8, six cases");
    reset_dut();
    for (t = 0; t < 4096; t = t + 1) s32.mem[t] = 8'h10 + t[7:0];

    // -------------------------------------------------------------------
    // Case 1: normal. The baseline the others are measured against.
    // -------------------------------------------------------------------
    op_read(32'h0000_0100, 4, got, cycles);
    check(got[31:0] === 32'h10111213, "case 1: data");
    check(cycles == 1,                "case 1: one bus cycle");
    check(req_end == 3'd1,            "case 1: req_end is CE_DSACK");

    // -------------------------------------------------------------------
    // Case 3: BERR in lieu of DSACK. $8000_0000 is unmapped, so nothing
    // answers and BERR is the only way the cycle can end.
    // -------------------------------------------------------------------
    begin
      bit          saw_fault;
      bit          saw_wr;
      logic [2:0]  saw_end;
      logic [31:0] saw_addr;
      logic  [2:0] saw_bytes;
      saw_fault = 1'b0;
      fork
        begin
          assert_at_n(1'b1, 1'b0);
          // req_fault and the residual are valid with req_ack, which is a
          // one-clock pulse, so they have to be sampled there.
          @(posedge req_ack);
          saw_fault = req_fault;
          saw_wr    = req_fault_wr;
          saw_end   = req_end;
          saw_addr  = flt_addr;
          saw_bytes = flt_bytes;
          release_exc();
        end
        op_read(32'h8000_0000, 4, got, cycles);
      join
      check(cycles == 1,       "case 3: the cycle ends rather than hanging");
      check(saw_fault,         "case 3: req_fault is raised with req_ack");
      check(!saw_wr,           "case 3: req_fault_wr is clear -- it was a read");
      check(saw_end == 3'd2,   "case 3: req_end is CE_BERR");
      check(saw_addr === 32'h8000_0000,
            "case 3: the residual address is the faulted access, not past it");
      check(saw_bytes == 3'd4,
            "case 3: the residual is the whole operand -- nothing was moved");
    end

    // A faulted WRITE reports req_fault_wr, which the special status word needs.
    begin
      bit saw_wr;
      saw_wr = 1'b0;
      fork
        begin
          assert_at_n(1'b1, 1'b0);
          @(posedge req_ack);
          saw_wr = req_fault_wr;
          release_exc();
        end
        op_write(32'h8000_0010, 2, 40'h00_0000_BEEF, cycles);
      join
      check(saw_wr, "a faulted write reports req_fault_wr");
    end

    // -------------------------------------------------------------------
    // Case 5: BERR and HALT in lieu of DSACK -- retry. A mapped address, so the
    // rerun succeeds and the operand completes with the right data.
    // -------------------------------------------------------------------
    a0 = as_count;
    fork
      begin
        assert_at_n(1'b1, 1'b1);
        repeat (2) @(posedge clk);
        berr_drv = 1'b0;
        halt_drv = 1'b0;
      end
      op_read(32'h0000_0100, 4, got, cycles);
    join
    check(got[31:0] === 32'h10111213, "case 5: the retried cycle returns the data");
    $sformat(what, "case 5: two bus cycles -- the original and the rerun (got %0d)", cycles);
    check(cycles == 2, what);

    // -------------------------------------------------------------------
    // Case 6: BERR and HALT one state pair after DSACK -- the late retry.
    // -------------------------------------------------------------------
    fork
      begin
        assert_at_n2(1'b1, 1'b1);
        repeat (2) @(posedge clk);
        berr_drv = 1'b0;
        halt_drv = 1'b0;
      end
      op_read(32'h0000_0104, 4, got, cycles);
    join
    check(got[31:0] === 32'h14151617, "case 6: the retried cycle returns the data");
    $sformat(what, "case 6: two bus cycles (got %0d)", cycles);
    check(cycles == 2, what);

    // -------------------------------------------------------------------
    // Case 2: HALT at state n, no BERR. The cycle completes normally; the next
    // one does not start until HALT is negated. UM 5.5.3: "HALT by itself does
    // not terminate a bus cycle."
    // -------------------------------------------------------------------
    fork
      assert_at_n(1'b0, 1'b1);
      op_read(32'h0000_0108, 4, got, cycles);
    join
    check(got[31:0] === 32'h18191A1B, "case 2: the cycle completes normally");
    check(cycles == 1,                "case 2: one bus cycle");

    // While halted: the data bus is released, AS and DS are negated but still
    // driven, and the address group stays driven (UM 5.5.3).
    repeat (2) @(posedge clk);
    check(d_oe === 1'b0,  "halted: the data bus is high impedance");
    check(as_n_o === 1'b1, "halted: AS is negated");
    check(as_oe === 1'b1,  "halted: AS is negated, not released");
    check(a_oe === 1'b1,   "halted: the address group remains driven");

    // A request made while halted must wait.
    a0 = as_count;
    fork
      begin
        repeat (8) @(posedge clk);
        check(as_count == a0, "halted: no bus cycle starts while HALT is asserted");
        @(posedge clk);
        halt_drv = 1'b0;
      end
      op_read(32'h0000_010C, 4, got, cycles);
    join
    check(got[31:0] === 32'h1C1D1E1F, "halted: the cycle runs once HALT is negated");

    // -------------------------------------------------------------------
    // Case 4: BERR one state pair after DSACK -- the late bus error. The cycle
    // terminated normally and the exception is taken anyway.
    // -------------------------------------------------------------------
    begin
      bit saw_fault;
      saw_fault = 1'b0;
      fork
        begin
          assert_at_n2(1'b1, 1'b0);
          @(posedge req_ack);
          saw_fault = req_fault;
          release_exc();
        end
        op_read(32'h0000_0110, 4, got, cycles);
      join
      check(saw_fault, "case 4: a BERR one state pair after DSACK raises req_fault");
    end

    // -------------------------------------------------------------------
    // AVEC -- UM 5.4.1: "the AVEC signal can be used to terminate interrupt
    // acknowledge cycles ... AVEC is ignored during all other bus cycles."
    // A board that ties it low -- a Sun-3/60 replica autovectors everything
    // that way -- must still see its ordinary cycles wait for DSACK. The slave
    // at $3000_0000 inserts three wait states, so a cycle AVEC ended would end
    // at the first sample, before its data, and report CE_AVEC.
    // -------------------------------------------------------------------
    avec_drv = 1'b1;
    op_write(32'h3000_0100, 4, 40'h00_CAFE_F00D, cycles);
    check(req_end == 3'd1, "AVEC on a write: ignored, the cycle ends on DSACK");
    check({sw.mem[12'h100], sw.mem[12'h101], sw.mem[12'h102], sw.mem[12'h103]}
          === 32'hCAFE_F00D, "AVEC on a write: the slave took the data");
    op_read(32'h3000_0100, 4, got, cycles);
    check(req_end == 3'd1, "AVEC on a read: ignored, the cycle ends on DSACK");
    check(got[31:0] === 32'hCAFE_F00D, "AVEC on a read: the data came back");

    // ... and on an interrupt acknowledge it still ends the cycle, with nothing
    // else answering: CPU space type $F, level 5, where no slave lives.
    req_fc       = 3'b111;
    req_cpuspace = 4'hF;
    req_cpuaddr  = 8'd5;
    op_read(32'h0, 1, got, cycles);
    check(req_end == 3'd4, "AVEC on an interrupt acknowledge: ends it, CE_AVEC");
    check(cycles == 1,     "AVEC on an interrupt acknowledge: one cycle");
    req_fc       = 3'b101;
    req_cpuspace = 4'd0;
    req_cpuaddr  = 8'd0;
    avec_drv     = 1'b0;

    $display("bus_error_tb: %0d checks, %0d failures, %0d drive violations",
             checks, fails, drive_violations);
    if (fails == 0 && drive_violations == 0) $display("PASS: bus_error_tb");
    else                                     $display("FAIL: bus_error_tb");
    $finish;
  end

  initial begin
    #500_000;
    $display("FAIL: bus_error_tb timed out");
    $finish;
  end

endmodule
