// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68021

// RD68021 - SystemVerilog MC68020
//
// Two-rank input synchroniser.
//
// UM 5.1: "for all inputs, the processor latches the level of the input during a
// sample window around the falling edge of the clock signal" (figure 5-2), and
// figure 5-1 shows the synchronisation delay that follows. Both ranks are therefore
// negative-edge clocked.
//
// This is for the inputs that may change at any time relative to a bus cycle: IPL,
// RESET, HALT, CDIS, BR and BGACK. DSACK, BERR, AVEC and the HALT that terminates a
// cycle are sampled directly by the bus unit's falling-edge next-state logic, which
// is the sample UM 5.2.6 describes and which must not have a rank of latency added
// to it.

module rd68021_sync #(
    parameter int WIDTH = 1,
    // Explicit, because there is no power-on state: an active-low input resets to
    // its negated value so that nothing looks asserted while rst_n is held. Sized
    // by WIDTH rather than fixed at 32 bits, or every instantiation is a
    // width-expansion warning.
    parameter logic [WIDTH-1:0] RESET_VAL = '1
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic [WIDTH-1:0] d,
    output logic [WIDTH-1:0] q
);

  logic [WIDTH-1:0] rank0;

  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rank0 <= RESET_VAL;
      q     <= RESET_VAL;
    end else begin
      rank0 <= d;
      q     <= rank0;
    end
  end

endmodule
