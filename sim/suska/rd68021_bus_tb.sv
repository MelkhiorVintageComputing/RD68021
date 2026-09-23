// RD68021 -- the bus probe, on this core, for comparison with the Suska WF68K30L.
//
// sim/suska/wf68k30l_tb.vhd runs sim/suska/bus_probe.S on the other core and
// prints one line per bus cycle; this prints the same lines for this core, from
// the same image, against the same memory map (the core harness's three ports
// are the probe's three). tools/suska_diff.py compares the data cycles.

`timescale 1ns / 1ps

module rd68021_bus_tb;

`include "rd68021_core_harness.svh"

  localparam int LIMIT = 20000;

  logic [2:0]  fc_q;
  logic [31:0] a_q, d_q;
  logic [1:0]  s_q;
  logic        rw_q, rmc_q;
  string       image;

  // Latched on every falling edge while AS is asserted, so the write data is
  // what was driven last -- the same rule the VHDL testbench follows.
  always @(negedge clk) if (rst_n && !as_n_o) begin
    fc_q = fc_o; a_q = a_o; s_q = siz_o; rw_q = rw_o; rmc_q = rmc_n_o;
    d_q  = rw_o ? 32'd0 : d_o;
  end

  always @(posedge as_n_o) if (rst_n)
    $display("BUS %0d %08h %0d %s %08h %s", fc_q, a_q, s_q, rw_q ? "R" : "W", d_q,
             rmc_q ? "-" : "RMC");

  // +trace=<lo>:<hi>: the micro-PC every clock while stage D is in that range.
  logic [31:0] tr_lo, tr_hi;
  initial begin
    tr_lo = 32'hFFFF_FFFF; tr_hi = 32'd0;
    void'($value$plusargs("tracelo=%h", tr_lo));
    void'($value$plusargs("tracehi=%h", tr_hi));
  end
  always @(negedge clk)
    if (rst_n && dut.u_ifu.pc_d >= tr_lo && dut.u_ifu.pc_d <= tr_hi)
      $display("  TRACE pc_d=%08h stg_d=%04h upc=%0d retire=%b as=%b a=%08h",
               dut.u_ifu.pc_d, dut.u_ifu.stg_d, dut.u_seq.upc, dut.u_seq.retire,
               as_n_o, a_o);

  initial begin
    if (!$value$plusargs("image=%s", image)) image = "build/suska/bus_probe.hex";
    // All three memories start at zero, as the VHDL testbench's do.
    for (int i = 0; i < 65536; i++) begin
      s32.mem[i] = 8'h00; s16.mem[i] = 8'h00; s8.mem[i] = 8'h00;
    end
    $readmemh(image, s32.mem);
    reset_dut();
    repeat (LIMIT) @(posedge clk);
    $finish;
  end

endmodule
