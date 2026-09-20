// RD68021 -- the core-level test harness.
//
// The whole processor against memory: a 32-bit port at $0000_0000 holding the
// exception vectors, and 16- and 8-bit ports at $1000_0000 and $2000_0000 so
// that the same program can be run through each and give the same answer.
//
// Instruction boundaries are sampled on the FALLING edge. The bus unit's output
// stage is negative-edge clocked and the acknowledge only settles in the second
// half of the clock, so a testbench that samples just after the rising edge
// misses the end of a bus-cycle microword.

localparam real CLK_PERIOD = 60.0;

logic clk;
logic rst_n;

// Pins.
logic  [2:0] fc_o;
logic        fc_oe;
logic [31:0] a_o;
logic        a_oe;
logic [31:0] d_o;
logic        d_oe;
logic  [1:0] siz_o;
logic        siz_oe;
logic        ecs_n_o, ocs_n_o;
logic        rw_o, rw_oe;
logic        rmc_n_o, rmc_oe;
logic        as_n_o, as_oe;
logic        ds_n_o, ds_oe;
logic        dben_o, dben_oe;
logic  [1:0] dsack_n_i;
logic        ipend_n_o;
logic        bg_n_o;
logic        reset_n_o, reset_n_oe;
logic        halt_n_o, halt_n_oe;

wire [31:0] dbus;
assign dbus = d_oe ? d_o : 32'bz;

rd68021_top dut (
    .clk (clk), .rst_n (rst_n),
    .fc_o (fc_o), .fc_oe (fc_oe),
    .a_o (a_o), .a_oe (a_oe),
    .d_i (dbus), .d_o (d_o), .d_oe (d_oe),
    .siz_o (siz_o), .siz_oe (siz_oe),
    .ecs_n_o (ecs_n_o), .ocs_n_o (ocs_n_o),
    .rw_o (rw_o), .rw_oe (rw_oe),
    .rmc_n_o (rmc_n_o), .rmc_oe (rmc_oe),
    .as_n_o (as_n_o), .as_oe (as_oe),
    .ds_n_o (ds_n_o), .ds_oe (ds_oe),
    .dben_o (dben_o), .dben_oe (dben_oe),
    .dsack_n_i (dsack_n_i),
    .ipl_n_i (3'b111), .ipend_n_o (ipend_n_o), .avec_n_i (1'b1),
    .br_n_i (1'b1), .bg_n_o (bg_n_o), .bgack_n_i (1'b1),
    .berr_n_i (1'b1),
    .reset_n_i (1'b1), .reset_n_o (reset_n_o), .reset_n_oe (reset_n_oe),
    .halt_n_i (1'b1), .halt_n_o (halt_n_o), .halt_n_oe (halt_n_oe),
    .cdis_n_i (1'b1)
);

logic [1:0] dsack32, dsack16, dsack8;
wire [31:0] d32, d16, d8;
logic       oe32, oe16, oe8;

assign dbus = oe32 ? d32 : 32'bz;
assign dbus = oe16 ? d16 : 32'bz;
assign dbus = oe8  ? d8  : 32'bz;
assign dsack_n_i = dsack32 & dsack16 & dsack8;

rd68021_slave #(.PORT_BYTES (4), .WAITS (0), .BASE (32'h0000_0000),
                .MASK (32'hF000_0000), .ABITS (13)) s32 (
    .clk (clk), .rst_n (rst_n), .a_i (a_o), .siz_i (siz_o), .fc_i (fc_o),
    .as_n_i (as_n_o), .ds_n_i (ds_n_o), .rw_i (rw_o), .d_i (dbus),
    .d_o (d32), .d_oe (oe32), .dsack_n_o (dsack32));

rd68021_slave #(.PORT_BYTES (2), .WAITS (0), .BASE (32'h1000_0000),
                .MASK (32'hF000_0000), .ABITS (13)) s16 (
    .clk (clk), .rst_n (rst_n), .a_i (a_o), .siz_i (siz_o), .fc_i (fc_o),
    .as_n_i (as_n_o), .ds_n_i (ds_n_o), .rw_i (rw_o), .d_i (dbus),
    .d_o (d16), .d_oe (oe16), .dsack_n_o (dsack16));

rd68021_slave #(.PORT_BYTES (1), .WAITS (0), .BASE (32'h2000_0000),
                .MASK (32'hF000_0000), .ABITS (13)) s8 (
    .clk (clk), .rst_n (rst_n), .a_i (a_o), .siz_i (siz_o), .fc_i (fc_o),
    .as_n_i (as_n_o), .ds_n_i (ds_n_o), .rw_i (rw_o), .d_i (dbus),
    .d_o (d8), .d_oe (oe8), .dsack_n_o (dsack8));

initial begin
  clk = 1'b0;
  forever #(CLK_PERIOD/2.0) clk = ~clk;
end

int unsigned fails;
int unsigned checks;
initial begin
  fails  = 0;
  checks = 0;
end

task automatic check(input bit ok, input string what);
  checks = checks + 1;
  if (!ok) begin
    fails = fails + 1;
    $display("  FAIL: %s", what);
  end
endtask

task automatic reset_dut();
  rst_n = 1'b0;
  repeat (4) @(posedge clk);
  rst_n = 1'b1;
endtask

// Write one word into whichever slave owns the address.
task automatic poke_w(input logic [31:0] a, input logic [15:0] v);
  case (a[31:28])
    4'h0: begin s32.mem[a[12:0]] = v[15:8]; s32.mem[a[12:0] + 1] = v[7:0]; end
    4'h1: begin s16.mem[a[12:0]] = v[15:8]; s16.mem[a[12:0] + 1] = v[7:0]; end
    4'h2: begin s8.mem[a[12:0]]  = v[15:8]; s8.mem[a[12:0] + 1]  = v[7:0]; end
    default: $display("  FAIL: poke_w to unmapped %08h", a);
  endcase
endtask

task automatic poke_l(input logic [31:0] a, input logic [31:0] v);
  poke_w(a,        v[31:16]);
  poke_w(a + 2,    v[15:0]);
endtask

// ---------------------------------------------------------------------------
// Instruction boundaries, and the pipe invariant
//
// UM 6.2: "when the short bus fault stack frame applies, the address of the pipe
// stage B word is the value in the PC plus four, and the address of the stage C
// word is the value in the PC plus two". That holds at an instruction boundary,
// where the pipe is sequential, and it is exactly what the short fault frame
// relies on -- so it is checked at every boundary rather than assumed.
//
// stg_b_addr is the address of the word in stage B, or of the word destined for
// it when the queue is not yet two deep, so the invariant reads the same whether
// the queue holds one word or two. It is guarded only on the queue not being
// empty: with nothing queued at all -- which happens for a clock or two after a
// flush -- the next word to arrive is the one at PC plus two, not PC plus four.
// ---------------------------------------------------------------------------
wire seq_is_decode =
    (dut.u_seq.uw[rd68021_ucode_pkg::U_SEQ_LSB +: rd68021_ucode_pkg::U_SEQ_W]
     == rd68021_ucode_pkg::U_SEQ_DECODE);
wire boundary = dut.u_seq.retire && seq_is_decode;

int unsigned instructions;
int unsigned pipe_checks;
int unsigned pipe_fails;
logic        boundary_q;

initial begin
  instructions = 0;
  pipe_checks  = 0;
  pipe_fails   = 0;
  boundary_q   = 1'b0;
end

always @(negedge clk) begin
  if (rst_n) begin
    if (boundary) instructions = instructions + 1;
    // One clock after a boundary, stage D holds the new opcode.
    if (boundary_q && dut.u_ifu.pf_dvalid && (dut.u_ifu.cnt_q != 2'd0)) begin
      pipe_checks = pipe_checks + 1;
      if (dut.u_ifu.stg_b_addr !== dut.u_ifu.pc_d + 32'd4) begin
        pipe_fails = pipe_fails + 1;
        // One string: iverilog does not concatenate adjacent string literals.
        $display("  FAIL: at %0t the pipe is not sequential: pc_d=%08h stg_b_addr=%08h, want pc_d+4",
                 $time, dut.u_ifu.pc_d, dut.u_ifu.stg_b_addr);
      end
    end
    boundary_q = boundary;
  end
end

// Run until the program counter settles on `spin`, or give up.
// A while loop rather than a for with a return: iverilog rejects `return` in a
// task ("Cannot return from tasks").
task automatic run_until(input logic [31:0] spin, input int limit,
                         output bit reached);
  int n;
  reached = 1'b0;
  n       = 0;
  while (!reached && n < limit) begin
    @(negedge clk);
    if (dut.u_ifu.pc_d === spin && dut.u_ifu.pf_dvalid) reached = 1'b1;
    n = n + 1;
  end
endtask
