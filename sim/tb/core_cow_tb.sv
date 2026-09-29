// RD68021 -- copy-on-write: a user-mode write fault, handled by a supervisor that
// does real work, and RTE back into user mode to restart the write cleanly.
//
// The program is sim/programs/cow.S, built by the cross-toolchain; this is the
// MMU and the judge. User-data writes (FC = 1) to the pages at $4000-$5FFF are
// refused with a bus error until the kernel writes a page's address to its page
// table port, and a refused write does not reach memory -- `wr_protect` in the
// harness. Every shape of write the program makes has to land exactly once,
// with every other effect of its instruction exactly once, after the kernel's
// handler has been through the processor's internal state.

`timescale 1ns / 1ps

module core_cow_tb;

`include "rd68021_core_harness.svh"

  localparam logic [31:0] ISP0    = 32'h0000_3000;
  localparam logic [31:0] KVARS   = 32'h0000_2000;
  localparam logic [31:0] KLOG    = 32'h0000_2010;
  localparam logic [31:0] PAGER   = 32'h0000_27F0;
  localparam logic [31:0] RESULTS = 32'h0000_6000;
  localparam logic [31:0] PTABLE  = 32'h0000_2600;
  localparam int          NFAULT  = 19;

  string       image;
  int unsigned n;
  logic [31:0] prot;             // one bit per 256-byte page, $4000-$5FFF
  logic        kprot;            // the kernel's page table, until it maps it
  int unsigned berrs;            // bus errors the MMU raised
  int unsigned unprotects;
  int unsigned user_on_sstack;
  logic [15:0] got_w;
  logic [31:0] got_l;

  // The MMU: a user-data write to a protected page is refused.
  function automatic bit refused(input logic [31:0] a, input logic [2:0] fc,
                                 input logic rw);
    refused = !rw && (fc == 3'd1) && (a >= 32'h4000) && (a < 32'h6000)
              && prot[5'((a - 32'h4000) >> 8)];
  endfunction

  // ... and a supervisor-data read of the kernel's page table, until the kernel
  // maps it: the first handler faults inside itself.
  always @(*) berr_force = rst_n && as_oe && !as_n_o
                           && (refused(a_o, fc_o, rw_o)
                               || (kprot && rw_o && fc_o == 3'd5
                                   && (a_o & 32'hFFFF_FF00) == PTABLE));
  always @(posedge berr_force) berrs = berrs + 1;

  // The page table: a supervisor write of a page's address maps it writable.
  always @(negedge ds_n_o)
    if (rst_n && !rw_o && (a_o == PAGER)) begin
      if (d_o >= 32'h4000 && d_o < 32'h6000) prot[5'((d_o - 32'h4000) >> 8)] = 1'b0;
      if (d_o == PTABLE)                      kprot = 1'b0;
      unprotects = unprotects + 1;
    end

  // UM table 2-1: the supervisor stack is the supervisor's. No user-space cycle
  // may touch it, frame building included.
  always @(negedge as_n_o)
    if (rst_n && as_oe && (fc_o == 3'd1 || fc_o == 3'd2)
        && a_o >= ISP0 - 32'h800 && a_o < ISP0)
      user_on_sstack++;

  function automatic logic [31:0] peek_ul(input logic [31:0] a);   // unaligned
    peek_ul = {s32.mem[a[15:0]], s32.mem[a[15:0] + 1],
               s32.mem[a[15:0] + 2], s32.mem[a[15:0] + 3]};
  endfunction

  // The kernel's log, in the order the faults came: the fault address, and the
  // SSW's size field -- UM 6.2.1, 00 long, 01 byte, 10 word, 11 three bytes.
  logic [31:0] want_addr [0:NFAULT-1];
  logic  [1:0] want_size [0:NFAULT-1];
  logic [15:0] want_ssw  [0:NFAULT-1];   // DF, RW and FC -- the bits in $0147
  logic  [7:0] want_srhi [0:NFAULT-1];   // the stacked SR's system byte
  string       want_what [0:NFAULT-1];
  task automatic want_fault(input int i, input logic [31:0] a, input logic [1:0] sz,
                        input string w);
    want_addr[i] = a; want_size[i] = sz; want_what[i] = w;
    want_ssw[i]  = 16'h0101;               // DF, a write, user data
    want_srhi[i] = 8'h00;                  // the user's
  endtask

  initial begin
    $display("core_cow_tb: copy-on-write faults in user mode, handled, and restarted");
    if (!$value$plusargs("image=%s", image)) image = "build/programs/cow.hex";
    for (n = 0; n < 65536; n = n + 1) s32.mem[n] = 8'h00;
    $readmemh(image, s32.mem);

    prot           = 32'hFFFF_FFFF;
    kprot          = 1'b1;
    berrs          = 0;
    unprotects     = 0;
    user_on_sstack = 0;
    wr_protect     = 1'b1;

    want_fault( 0, 32'h0000_4010, 2'b00, "MOVE.L D1,(A0)");
    // The first handler's own page-table read: a supervisor data read, DF set,
    // with the handler's status register -- S set -- on the second frame.
    want_fault( 1, PTABLE, 2'b00, "the handler's page-table read, nested");
    want_ssw[1]  = 16'h0145;
    want_srhi[1] = 8'h20;
    want_fault( 2, 32'h0000_4110, 2'b00, "MOVE.L D1,(A0)+");
    want_fault( 3, 32'h0000_421E, 2'b10, "MOVE.W D1,-(A0)");
    want_fault( 4, 32'h0000_4338, 2'b00, "MOVE.L (A1),8(A0)");
    want_fault( 5, 32'h0000_4410, 2'b00, "ADDQ.L #3,(A0)");
    want_fault( 6, 32'h0000_4510, 2'b01, "BSET #5,(A0)");
    want_fault( 7, 32'h0000_4610, 2'b10, "BFINS D2,(A0){4:8}");
    want_fault( 8, 32'h0000_4710, 2'b00, "CAS.L D3,D4,(A0)");
    want_fault( 9, 32'h0000_4800, 2'b10, "MOVE.L D1,$47FE -- the second word");
    want_fault(10, 32'h0000_4900, 2'b11, "MOVE.L D1,$48FF -- the last three bytes");
    want_fault(11, 32'h0000_4AFE, 2'b00, "MOVE.L D1,$4AFE -- first fault");
    want_fault(12, 32'h0000_4B00, 2'b10, "MOVE.L D1,$4AFE -- second fault, the residual");
    want_fault(13, 32'h0000_4C40, 2'b00, "MOVE.L D4,(A0) -- the kernel writes it");
    want_fault(14, 32'h0000_5EFC, 2'b00, "JSR -- the return address");
    want_fault(15, 32'h0000_5DFC, 2'b00, "LINK -- the frame pointer");
    want_fault(16, 32'h0000_5CFC, 2'b00, "MOVEM.L D1-D4,-(SP) -- the third register");
    want_fault(17, 32'h0000_5AFC, 2'b00, "PEA");
    want_fault(18, 32'h0000_59FE, 2'b01, "MOVE.B D1,-(SP)");

    reset_dut();
    n = 0;
    while (peek_l(KVARS + 8) == 32'd0 && n < 400000) begin
      @(negedge clk);
      n = n + 1;
    end
    $display("core_cow_tb: %0d clocks, %0d bus errors, %0d pages mapped", n, berrs,
             unprotects);

    // ------------------------------------------------------------------
    // It finished, in the privilege violation handler: still a user program.
    // ------------------------------------------------------------------
    check(peek_l(KVARS + 8) === 32'h0000_600D,
          "the program ends in the privilege violation handler, not elsewhere");
    got_w = peek_w(KVARS + 32'hC);
    check(got_w[13] === 1'b0,
          "the privileged instruction was executed in user mode: S clear in its frame");
    check(dut.u_seq.isp_q === ISP0 - 32'd8,
          "every bus error frame came off the supervisor stack; only the last trap's is on it");
    check(user_on_sstack == 0, "no user-space cycle touched the supervisor stack");

    // ------------------------------------------------------------------
    // The faults, as the kernel logged them.
    // ------------------------------------------------------------------
    check(peek_l(KVARS) === NFAULT, $sformatf("the kernel took %0d faults, want %0d",
                                              peek_l(KVARS), NFAULT));
    check(berrs == NFAULT, $sformatf("the MMU refused %0d accesses, want %0d",
                                     berrs, NFAULT));
    for (n = 0; n < NFAULT; n = n + 1) begin
      logic [31:0] a;
      logic [15:0] ssw, sr;
      a   = peek_l(KLOG + 8 * n);
      ssw = peek_w(KLOG + 8 * n + 4);
      sr  = peek_w(KLOG + 8 * n + 6);
      check(a === want_addr[n],
            $sformatf("fault %0d, %s: at %08h, want %08h", n, want_what[n], a, want_addr[n]));
      // DF set, a write, user data space: UM 6.2.1 and doc/ssw.md.
      check((ssw & 16'h0147) === want_ssw[n],
            $sformatf("fault %0d, %s: SSW %04h, want DF/RW/FC %04h",
                      n, want_what[n], ssw, want_ssw[n]));
      check(ssw[5:4] === want_size[n],
            $sformatf("fault %0d, %s: SSW size %0d, want %0d", n, want_what[n],
                      ssw[5:4], want_size[n]));
      check(sr[15:8] === want_srhi[n],
            $sformatf("fault %0d, %s: the stacked SR %04h, want system byte %02h", n,
                      want_what[n], sr, want_srhi[n]));
    end

    // ------------------------------------------------------------------
    // Every write landed, once.
    // ------------------------------------------------------------------
    check(peek_l(32'h4010) === 32'h1111_1111, "MOVE.L D1,(A0): written");
    check(peek_l(32'h4110) === 32'h1111_1111, "MOVE.L D1,(A0)+: written");
    check(peek_l(RESULTS + 0) === 32'h0000_4114, "MOVE.L D1,(A0)+: A0 stepped once");
    check(peek_w(32'h421E) === 16'h1111, "MOVE.W D1,-(A0): written");
    check(peek_l(RESULTS + 4) === 32'h0000_421E, "MOVE.W D1,-(A0): A0 stepped once");
    check(peek_l(32'h4338) === 32'h5EED_5EED, "MOVE.L (A1),8(A0): the source's value");
    check(peek_l(32'h4410) === 32'd13, "ADDQ.L #3,(A0): 10 + 3, once");
    check(peek_w(RESULTS + 8) === 16'h0000, "ADDQ.L #3,(A0): its condition codes");
    got_w = peek_w(32'h4510);
    check(got_w[15:8] === 8'h21, "BSET #5,(A0): set, and bit 0 kept");
    check(peek_w(RESULTS + 32'hA) === 16'h0004, "BSET #5,(A0): Z, the bit was clear");
    check(peek_l(32'h4610) === 32'h1AB4_5678, "BFINS D2,(A0){4:8}: $AB in bits 4-11");
    check(peek_l(32'h4710) === 32'hFEED_F00D, "CAS.L: the update operand written");
    check(peek_w(RESULTS + 32'hC) === 16'h0004, "CAS.L: Z, the compare was equal");
    check(peek_ul(32'h47FE) === 32'h1111_1111, "MOVE.L D1,$47FE: all four bytes");
    check(peek_ul(32'h48FF) === 32'h1111_1111, "MOVE.L D1,$48FF: all four bytes");
    check(peek_ul(32'h4AFE) === 32'h1111_1111, "MOVE.L D1,$4AFE: all four bytes");
    check(peek_l(32'h4C40) === 32'hFEED_F00D, "the kernel's own write: D4");
    check(prot[5'((32'h4C00 - 32'h4000) >> 8)] === 1'b1,
          "the kernel's own write: its page was never mapped");
    check(peek_l(32'h5EFC) !== 32'd0, "JSR: a return address was pushed");
    check(dut.u_seq.dreg[7] === 32'd1, "JSR: the subroutine ran once, and returned");
    check(peek_l(32'h5DFC) === 32'hA6A6_A6A6, "LINK: the old frame pointer pushed");
    check(peek_l(RESULTS + 32'hE) === 32'h0000_5DFC, "LINK: A6 is the new frame");
    check(peek_l(RESULTS + 32'h12) === 32'h0000_5E00, "UNLK: the stack is back");
    check(peek_l(RESULTS + 32'h16) === 32'hA6A6_A6A6, "UNLK: and A6");
    check(peek_l(32'h5CF8) === 32'h1111_1111 && peek_l(32'h5CFC) === 32'h0000_00AB
          && peek_l(32'h5D00) === 32'hCAFE_BABE && peek_l(32'h5D04) === 32'hFEED_F00D,
          "MOVEM.L D1-D4,-(SP): every register, in order");
    check(peek_l(RESULTS + 32'h1A) === 32'h0000_5CF8, "MOVEM.L D1-D4,-(SP): SP down 16, once");
    check(peek_l(32'h5AFC) === 32'h0000_1234, "PEA: the address pushed");
    check(peek_l(RESULTS + 32'h1E) === 32'h0000_5AFC, "PEA: SP down 4, once");
    got_w = peek_w(32'h59FE);
    check(got_w[15:8] === 8'h11, "MOVE.B D1,-(SP): the byte, at the even address");
    check(peek_l(RESULTS + 32'h22) === 32'h0000_59FE, "MOVE.B D1,-(SP): SP down 2, once");

    // ------------------------------------------------------------------
    // The user's registers came through eighteen trips to the kernel, one of
    // them two frames deep.
    // ------------------------------------------------------------------
    check(dut.u_seq.dreg[1] === 32'h1111_1111, "D1 as the user left it");
    check(dut.u_seq.dreg[2] === 32'h0000_00AB, "D2 as the user left it");
    check(dut.u_seq.dreg[3] === 32'hCAFE_BABE, "D3 as the user left it");
    check(dut.u_seq.dreg[4] === 32'hFEED_F00D, "D4 as the user left it");
    check(dut.u_seq.areg[5] === RESULTS + 32'h26, "A5, the results pointer, stepped once per record");
    check(dut.u_seq.usp_q === 32'h0000_59FE, "the user stack pointer");

    if (pipe_fails != 0)
      $display("  FAIL: the pipe invariant broke %0d times", pipe_fails);
    $display("core_cow_tb: %0d checks, %0d failed", checks, fails);
    if (fails == 0 && pipe_fails == 0) $display("PASS: core_cow_tb");
    else                               $display("FAIL: core_cow_tb");
    $finish;
  end

endmodule
