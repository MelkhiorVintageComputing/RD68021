// RD68021 - SystemVerilog MC68020
//
// An output that changes on both clock edges, built from a positive-edge flop and a
// negative-edge flop combined with XOR.
//
// Several pins assert on one edge of the bus-state ruler and negate on the other:
// AS and DS assert on the falling edge entering S1 and negate on the falling edge
// entering S5, and ECS and OCS assert on a rising edge and negate on the very next
// falling edge -- one half clock, which is what specification 10 measures.
//
// Only one side can change at any instant, so the XOR is glitch-free, and every one
// of the six front-ends infers it correctly (doc/coding-standard.md, measured).
//
// set_p toggles the positive-edge half, set_n the negative-edge half. The output is
// the XOR, so the caller arranges for the two halves to disagree exactly while the
// signal is asserted.

module rd68021_dedge_ff #(
    parameter bit RESET_VAL = 1'b0
) (
    input  logic clk,
    input  logic rst_n,
    input  logic toggle_p,   // flip on the next rising edge
    input  logic toggle_n,   // flip on the next falling edge
    output logic q
);

  logic half_p;
  logic half_n;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      half_p <= RESET_VAL;
    end else if (toggle_p) begin
      half_p <= ~half_p;
    end
  end

  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      half_n <= 1'b0;
    end else if (toggle_n) begin
      half_n <= ~half_n;
    end
  end

  assign q = half_p ^ half_n;

endmodule
