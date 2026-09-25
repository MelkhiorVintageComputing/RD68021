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

// The asynchronous inputs, driven rather than tied, so a testbench can raise an
// interrupt or answer an acknowledge cycle. Everything that does not care gets
// the idle level and never touches them.
logic  [2:0] ipl_n_i;
logic        avec_n_i;
logic        cdis_n_i;
initial begin
  cdis_n_i = 1'b1;
  ipl_n_i  = 3'b111;
  avec_n_i = 1'b1;
end

// BERR has two sources and one pin, so the pin is driven here and the two ways
// of asking for it are variables a testbench sets.
//
//   `berr_force`  assert it for whatever cycle is running -- an acknowledge
//                 cycle nobody answers, say
//   `berr_base` / `berr_mask`   a region of the address map that answers with a
//                 bus error instead of with data, which is what a page that is
//                 not resident looks like. `berr_en` turns it on.
//
// The region is switched off by a bit of its own rather than by an address no
// cycle can use, because there is no such address: the first attempt parked it
// at $FFFF_FFFF, which is exactly where a level 7 interrupt acknowledge goes --
// UM figure 5-31 puts the level on A3-A1 with every bit above them set.
//
//   `berr_late`   the region answers with DSACK and THEN a bus error, after the
//                 bus unit's first sample -- UM Table 5-8 case 4, which only the
//                 second sample, entering S5, sees. That is the one fault an
//                 early retire has to see coming.
logic        berr_n_i;
logic        berr_force;
logic        berr_en;
logic        berr_late;
logic [31:0] berr_base;
logic [31:0] berr_mask;
initial begin
  berr_force = 1'b0;
  berr_en    = 1'b0;
  berr_late  = 1'b0;
  berr_base  = 32'd0;
  berr_mask  = 32'hFFFF_FFFF;
end

wire berr_region = berr_en && rst_n && as_oe
                && ((a_o & berr_mask) == (berr_base & berr_mask));
wire berr_hit    = berr_region && !berr_late && !as_n_o;
wire berr_late_hit = berr_region && berr_late
                  && (dut.u_biu.st_n == rd68021_pkg::ST_S3);

assign berr_n_i = ~(berr_force | berr_hit | berr_late_hit);

wire [31:0] dbus;
assign dbus = d_oe ? d_o : 32'bz;

// The cache size comes from the Makefile's ICACHE_ENTRIES, so that `make cache`
// can run every core testbench at both 64 and 0. A testbench that is ABOUT the
// cache sets it itself before including this.
`ifndef TB_ICACHE_ENTRIES
`define TB_ICACHE_ENTRIES 64
`endif

// The coprocessor interface is built only when a testbench asks for it, and a
// testbench that does gets the scripted coprocessor of sim/models/rd68021_cpmodel.sv
// at CpID 1 as well.
`ifdef TB_COPROCESSOR
localparam bit TB_CP = 1'b1;
`else
localparam bit TB_CP = 1'b0;
`endif

rd68021_top #(.ICACHE_ENTRIES (`TB_ICACHE_ENTRIES),
              .COPROCESSOR (TB_CP)) dut (
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
    .ipl_n_i (ipl_n_i), .ipend_n_o (ipend_n_o), .avec_n_i (avec_n_i),
    .br_n_i (1'b1), .bg_n_o (bg_n_o), .bgack_n_i (1'b1),
    .berr_n_i (berr_n_i),
    .reset_n_i (1'b1), .reset_n_o (reset_n_o), .reset_n_oe (reset_n_oe),
    .halt_n_i (1'b1), .halt_n_o (halt_n_o), .halt_n_oe (halt_n_oe),
    .cdis_n_i (cdis_n_i)
);

logic [1:0] dsack32, dsack16, dsack8;
wire [31:0] d32, d16, d8;
logic       oe32, oe16, oe8;

// One more device, for a testbench to wire in whatever the three memories are
// not. The interrupt acknowledge is the reason: its address is SYNTHESISED in
// CPU space, so no memory can ever be selected by it and something else has to
// answer. Left idle, it changes nothing.
logic  [1:0] dsack_ext;
logic [31:0] d_ext;
logic        oe_ext;
initial begin
  dsack_ext = 2'b11;
  d_ext     = 32'd0;
  oe_ext    = 1'b0;
end

assign dbus = oe32 ? d32 : 32'bz;
assign dbus = oe16 ? d16 : 32'bz;
assign dbus = oe8  ? d8  : 32'bz;
assign dbus = oe_ext ? d_ext : 32'bz;
wire  [1:0] dsack_cp;
`ifdef TB_COPROCESSOR
wire [31:0] d_cp;
wire        oe_cp;
assign dbus = oe_cp ? d_cp : 32'bz;
rd68021_cpmodel #(.CPID (3'd1)) cp (
    .clk (clk), .rst_n (rst_n), .a_i (a_o), .fc_i (fc_o), .siz_i (siz_o),
    .as_n_i (as_n_o), .ds_n_i (ds_n_o), .rw_i (rw_o), .d_i (dbus),
    .d_o (d_cp), .d_oe (oe_cp), .dsack_n_o (dsack_cp));
`else
assign dsack_cp = 2'b11;
`endif
assign dsack_n_i = dsack32 & dsack16 & dsack8 & dsack_ext & dsack_cp;

rd68021_slave #(.PORT_BYTES (4), .WAITS (0), .BASE (32'h0000_0000),
                .MASK (32'hF000_0000), .ABITS (16)) s32 (
    .clk (clk), .rst_n (rst_n), .a_i (a_o), .siz_i (siz_o), .fc_i (fc_o),
    .as_n_i (as_n_o), .ds_n_i (ds_n_o), .rw_i (rw_o), .d_i (dbus),
    .d_o (d32), .d_oe (oe32), .dsack_n_o (dsack32));

rd68021_slave #(.PORT_BYTES (2), .WAITS (0), .BASE (32'h1000_0000),
                .MASK (32'hF000_0000), .ABITS (16)) s16 (
    .clk (clk), .rst_n (rst_n), .a_i (a_o), .siz_i (siz_o), .fc_i (fc_o),
    .as_n_i (as_n_o), .ds_n_i (ds_n_o), .rw_i (rw_o), .d_i (dbus),
    .d_o (d16), .d_oe (oe16), .dsack_n_o (dsack16));

rd68021_slave #(.PORT_BYTES (1), .WAITS (0), .BASE (32'h2000_0000),
                .MASK (32'hF000_0000), .ABITS (16)) s8 (
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

// Reset is released on a FALLING edge, and never on the edge the design samples.
// Releasing it on a rising edge is a race: whether the always_ff blocks for that
// edge run before or after the testbench's blocking assignment is up to the
// simulator, so the reset branch may still fire and its non-blocking writes land
// after anything the testbench deposited. It cost an afternoon here, and adding
// a $display to find it made it go away.
task automatic reset_dut();
  rst_n = 1'b0;
  repeat (4) @(posedge clk);
  @(negedge clk);
  rst_n = 1'b1;
  @(negedge clk);
endtask

// Write one word into whichever slave owns the address. The index must be the
// same width the slave uses, or a poke lands somewhere the core will not read --
// and 64 KB is enough that nothing a test uses wraps onto the vector table.
task automatic poke_w(input logic [31:0] a, input logic [15:0] v);
  case (a[31:28])
    4'h0: begin s32.mem[a[15:0]] = v[15:8]; s32.mem[a[15:0] + 1] = v[7:0]; end
    4'h1: begin s16.mem[a[15:0]] = v[15:8]; s16.mem[a[15:0] + 1] = v[7:0]; end
    4'h2: begin s8.mem[a[15:0]]  = v[15:8]; s8.mem[a[15:0] + 1]  = v[7:0]; end
    default: $display("  FAIL: poke_w to unmapped %08h", a);
  endcase
endtask

task automatic poke_l(input logic [31:0] a, input logic [31:0] v);
  poke_w(a,        v[31:16]);
  poke_w(a + 2,    v[15:0]);
endtask

// ... and back out again, for a test that has to look at what the core wrote --
// a stack frame, say, which is only ever visible as memory.
function automatic logic [15:0] peek_w(input logic [31:0] a);
  case (a[31:28])
    4'h0: peek_w = {s32.mem[a[15:0]], s32.mem[a[15:0] + 1]};
    4'h1: peek_w = {s16.mem[a[15:0]], s16.mem[a[15:0] + 1]};
    4'h2: peek_w = {s8.mem[a[15:0]],  s8.mem[a[15:0] + 1]};
    default: peek_w = 16'hXXXX;
  endcase
endfunction

function automatic logic [31:0] peek_l(input logic [31:0] a);
  peek_l = {peek_w(a), peek_w(a + 2)};
endfunction

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

// When to look at it. A microword normally retires on a clock decided at the
// rising edge, but one the assembler marks `early` retires on the bus unit's
// word that the operand finished cleanly, which is a falling-edge register --
// so `retire` can rise at the falling edge itself. Sampling just after it sees
// both kinds, and both hold until the rising edge.
localparam real SETTLE = CLK_PERIOD / 8.0;

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
  #(SETTLE);
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

// One instruction. `boundary` is the retirement of a microword that decodes,
// which is what ends an instruction.
//
// The retiring microword's writes are non-blocking and land on the NEXT RISING
// edge, so the caller cannot compare anything until that edge has passed. It
// must not wait a whole falling edge for it: a one-microword instruction
// following this one retires on that very edge, and the next call to this task
// would step straight past its boundary and compare the wrong instruction.
// MOVEQ after a MOVE is what found it, 1652 instructions into a program.
task automatic step_one(input int limit, output bit ok);
  int n;
  ok = 1'b0;
  n  = 0;
  while (!ok && n < limit) begin
    @(negedge clk);
    #(SETTLE);
    if (boundary) ok = 1'b1;
    n = n + 1;
  end
  @(posedge clk);
  #(CLK_PERIOD / 4.0);
endtask

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

// ---------------------------------------------------------------------------
// Operand accesses, for comparison against an oracle's own list.
//
// An instruction prefetch is not an operand access, and the two cores do not
// fetch alike -- this one reads long words through a holding register and an
// interpreter reads whatever it needs. What both must agree about is the
// accesses an instruction makes because the program said so.
//
// The space is NOT the discriminator. PRM 2: "Data items in the instruction
// stream can be accessed with the program counter relative addressing modes;
// these accesses classify as program references", so a perfectly ordinary
// operand read comes out on the function code pins as program space. What
// separates the two is who asked, and the bus unit already knows -- op_isfetch
// tells its fault path which of its two requesters to report to.
// ---------------------------------------------------------------------------
localparam int MAXACC = 16;
int unsigned nacc;
logic [31:0] acc_addr [0:MAXACC-1];
logic        acc_rw   [0:MAXACC-1];
logic        acc_prog [0:MAXACC-1];
logic  [2:0] acc_bytes[0:MAXACC-1];
logic [31:0] acc_data [0:MAXACC-1];

// The unit recorded is the OPERAND, not the bus cycle. The two are not the same
// on this part: table 5-6 splits one misaligned operand across up to four
// cycles, so a long word read at an address ending in 10 is two cycles and one
// access. An interpreter has no notion of either, and what it reports is the
// operand.
//
// UM 5.1.1 names exactly this distinction in hardware -- ECS marks every bus
// cycle, OCS only the first cycle of an operand -- so the recorder triggers on
// OCS and nothing has to be inferred from the addresses.
//
// OCS is asserted for the half clock of S0 only, so there is no clock edge
// inside it to sample on. Sample a settled quarter-period after the rising edge
// that starts S0 instead: the address, function code and R/W are driven on that
// same edge, and a testbench may use a delay where the design may not.
initial nacc = 0;

always @(posedge clk) begin
  #(CLK_PERIOD / 4.0);
  if (rst_n && !ocs_n_o && !dut.u_biu.op_isfetch) begin
    if (nacc < MAXACC) begin
      acc_addr[nacc] = a_o;
      acc_rw[nacc]   = rw_o;
      acc_prog[nacc] = (fc_o == rd68021_pkg::FC_SUPER_PROG
                        || fc_o == rd68021_pkg::FC_USER_PROG);
      // op_rem is the byte count still to move, and at the first cycle of an
      // operand that is the whole operand. op_data is the write data, right
      // justified; on a read it is the accumulator and means nothing yet, so
      // the recorded value is zero there and the oracle sends zero too.
      acc_bytes[nacc] = dut.u_biu.op_rem;
      acc_data[nacc]  = rw_o ? 32'd0 : (dut.u_biu.op_data[31:0]
                                        & ~(32'hFFFF_FFFF << {dut.u_biu.op_rem, 3'b000}));
    end
    nacc = nacc + 1;
  end
end
