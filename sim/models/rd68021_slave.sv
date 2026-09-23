// RD68021 -- a bus slave with a selectable port width.
//
// Written from UM 5.2.1 and Tables 5-1, 5-4, 5-5 and 5-7, deliberately without
// reference to how rd68021_biu splits an operand: the point of the model is to
// answer the way a device answers, so that the two derivations of the byte-lane
// rules have to agree.
//
//   "Dynamic bus sizing requires that the portion of the data bus used for a
//    transfer to or from a particular port size be fixed. A 32-bit port must
//    reside on D31-D0, a 16-bit port must reside on D31-D16, and an 8-bit port
//    must reside on D31-D24."                                          -- UM 5.2.1
//
// So a device of PORT_BYTES width, addressed at a byte that lands OFF bytes into
// one of its own words, can move at most PORT_BYTES-OFF bytes in one cycle, and it
// puts the byte at address+j on lane OFF+j -- where lane 0 is D31-D24.
//
// DSACK is asserted on a RISING clock edge, never combinationally from AS: the
// processor samples it at the end of S2, which is a falling edge, and a model that
// answered combinationally would be testing a sample the manual does not describe.
//
// Testbenches are not bound by the rtl/ rules; this file uses initial blocks,
// associative arrays and $display freely.

`timescale 1ns / 1ps

module rd68021_slave #(
    parameter int PORT_BYTES = 4,       // 1, 2 or 4
    parameter int WAITS      = 0,       // wait states to insert
    parameter logic [31:0] BASE = 32'h0000_0000,
    parameter logic [31:0] MASK = 32'hFF00_0000,  // address & MASK == BASE selects
    parameter int ABITS      = 12                 // bytes of store, as a power of two
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [31:0] a_i,
    input  logic  [1:0] siz_i,
    input  logic  [2:0] fc_i,
    input  logic        as_n_i,
    input  logic        ds_n_i,
    input  logic        rw_i,
    input  logic [31:0] d_i,            // from the processor, on a write
    output logic [31:0] d_o,
    output logic        d_oe,
    output logic  [1:0] dsack_n_o
);

  // Byte-addressable store. A plain unpacked array rather than an associative one,
  // so that a testbench can reach into it hierarchically under every simulator.
  localparam int NBYTES = (1 << ABITS);
  logic [7:0] mem [0:NBYTES-1];

  function automatic int unsigned idx(input logic [31:0] a);
    idx = a % NBYTES;
  endfunction

  int unsigned wait_cnt;
  logic        answering;

  function automatic int unsigned siz_bytes(input logic [1:0] s);
    case (s)
      2'b01:   siz_bytes = 1;
      2'b10:   siz_bytes = 2;
      2'b11:   siz_bytes = 3;
      default: siz_bytes = 4;
    endcase
  endfunction

  function automatic int unsigned port_off(input logic [31:0] a);
    port_off = a % PORT_BYTES;
  endfunction

  // How many bytes this device can move this cycle.
  function automatic int unsigned xfer_n(input logic [31:0] a, input logic [1:0] s);
    int unsigned room;
    room   = PORT_BYTES - port_off(a);
    xfer_n = (siz_bytes(s) < room) ? siz_bytes(s) : room;
  endfunction

  logic selected;
  // A memory is never selected by a CPU-space cycle. UM figure 5-31: function
  // code 111 is where the processor talks to the things that are not memory --
  // the interrupt acknowledge, the breakpoint acknowledge, the coprocessor, the
  // access-level hardware -- and its addresses are synthesised, so they fall
  // wherever they fall. A breakpoint acknowledge for BKPT #5 is at $00000014,
  // which is inside this model's range, and without this the memory and the
  // breakpoint device both answered it.
  assign selected = !as_n_i && (fc_i != 3'b111) && ((a_i & MASK) == BASE);

  // The DSACK encoding for this port width -- UM Table 5-1, active low. A
  // localparam and an assign, not an always_comb: a process that reads only
  // parameters has no sensitivities, and iverilog says so for every instance.
  localparam logic [1:0] MY_DSACK = (PORT_BYTES == 1) ? 2'b10    // DSACK0 only
                                  : (PORT_BYTES == 2) ? 2'b01    // DSACK1 only
                                  :                     2'b00;   // both

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wait_cnt  <= 0;
      answering <= 1'b0;
    end else if (selected) begin
      if (wait_cnt >= WAITS) answering <= 1'b1;
      else                   wait_cnt  <= wait_cnt + 1;
    end else begin
      wait_cnt  <= 0;
      answering <= 1'b0;
    end
  end

  assign dsack_n_o = (selected && answering) ? MY_DSACK : 2'b11;

  // Read data. Driven whenever this device is selected and answering a read; the
  // lanes it does not own are left at zero, which a 32-bit test would notice.
  logic [7:0] rd_lane [0:3];
  int unsigned j;

  always_comb begin
    for (j = 0; j < 4; j = j + 1) rd_lane[j] = 8'h00;
    if (selected && rw_i) begin
      for (j = 0; j < 4; j = j + 1) begin
        if (j < xfer_n(a_i, siz_i)) begin
          rd_lane[port_off(a_i) + j] = mem[idx(a_i + j)];
        end
      end
    end
  end

  assign d_o  = {rd_lane[0], rd_lane[1], rd_lane[2], rd_lane[3]};
  assign d_oe = selected && rw_i && answering;

  // Write. The device latches on the edge it acknowledges, using R/W, DS, SIZ1,
  // SIZ0, A1 and A0 to pick its bytes (UM 5.3.2 state 3).
  logic [7:0] wr_lane [0:3];
  assign wr_lane[0] = d_i[31:24];
  assign wr_lane[1] = d_i[23:16];
  assign wr_lane[2] = d_i[15:8];
  assign wr_lane[3] = d_i[7:0];

  int unsigned k;
  always_ff @(negedge clk) begin
    if (rst_n && selected && !rw_i && !ds_n_i && answering) begin
      for (k = 0; k < 4; k = k + 1) begin
        if (k < xfer_n(a_i, siz_i)) begin
          mem[idx(a_i + k)] = wr_lane[port_off(a_i) + k];
        end
      end
    end
  end

  // Test access. A testbench may also reach mem[] directly.
  task automatic poke(input logic [31:0] a, input logic [7:0] v);
    mem[idx(a)] = v;
  endtask

  function automatic logic [7:0] peek(input logic [31:0] a);
    peek = mem[idx(a)];
  endfunction

  task automatic fill(input logic [7:0] v);
    int unsigned n;
    for (n = 0; n < NBYTES; n = n + 1) mem[n] = v;
  endtask

endmodule
