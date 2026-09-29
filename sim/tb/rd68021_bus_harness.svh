// RD68021 -- the bus-level test harness.
//
// Drives rd68021_biu on its own, against four slaves of different port widths, on
// a REAL three-state data bus: a stuck output enable shows up as an X rather than
// being quietly ignored by a multiplexer.
//
//   $0000_0000  32-bit port, no wait states
//   $1000_0000  16-bit port, no wait states
//   $2000_0000   8-bit port, no wait states
//   $3000_0000  32-bit port, three wait states
//
// THE STATE RULER. Every observation is indexed by half-clock tick from the rising
// edge that enters S0, because that is the ruler the manual uses: one bus state per
// CLK half period, so tick 0 is S0, tick 1 is S1, and so on. Pins are sampled SNAP
// nanoseconds after each edge, late enough that the edge has settled and early
// enough that nothing else has happened.
//
// CLK_PERIOD is 60 ns -- 16.67 MHz, the slowest speed grade in the manual's own
// clock table, and the one this design has to meet.
//
// This file is included inside a module, so it carries no `timescale of its own:
// the directive is not allowed there, and the including testbench sets it.

// The clock period, in nanoseconds. 60 ns -- 16.67 MHz -- is the slowest speed
// grade in the manual's own clock table and the default here, but the AC analysis
// needs one run per grade: the separations it measures are in clock edges, so a
// 16.67 MHz recording is evidence about 16.67 MHz and nothing else.
real CLK_PERIOD;

// Pins are sampled this long after each edge: late enough that the edge has
// settled, early enough that nothing else has happened.
localparam real SNAP = 5.0;

logic clk;
logic rst_n;

// Sequencer side of the bus unit.
logic        pending;
logic  [2:0] req_kind;
logic  [2:0] req_fc;
logic [31:0] req_addr;
logic  [2:0] req_bytes;
logic [39:0] req_wdata;
logic        req_rmc;
logic  [3:0] req_cpuspace;
logic  [7:0] req_cpuaddr;
logic        req_ack;
logic        req_last;
logic [39:0] req_rdata;
logic  [2:0] req_end;
logic        req_fault;
logic        req_fault_wr;
logic  [1:0] req_dsack;

// The contract: the operand completes at the rising edge that ends S5, and
// req_last says so throughout S5. A sequencer must present its next request or
// drop the current one within that half clock -- which is what the microword's
// successor previews are for, and what this models.
logic req_valid;
assign req_valid = pending && !req_last;

logic [31:0] flt_addr;
logic  [2:0] flt_bytes, flt_fc;
logic        flt_rw, flt_rmc;
logic [31:0] flt_dob, flt_dib;

logic        fetch_pending;
logic [31:0] fetch_addr;
logic  [2:0] fetch_fc;
logic        fetch_ack;
logic        fetch_last;
logic [31:0] fetch_rdata;
logic        fetch_fault;

// The fetch port has the same contract as the data port: the operand completes at
// the rising edge that ends S5, and fetch_last says so throughout S5. Holding
// fetch_valid past that edge starts a second, identical prefetch.
logic fetch_valid;
assign fetch_valid = fetch_pending && !fetch_last;

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
logic        bg_n_o;
logic        reset_n_o, reset_n_oe;
logic        halt_n_o, halt_n_oe;
logic  [2:0] ipl_sync_n;
logic        reset_sync_n, halt_sync_n, cdis_sync_n;
logic        bus_idle, bus_granted, reset_busy;

// Bus exception and arbitration inputs, driven by the test. UM 5.5 asks for BERR,
// HALT and DSACK to be "asserted and negated with the rising edge of the
// MC68020/EC020 clock ... this ensures that when two signals are asserted
// simultaneously, the required setup time (#47A) and hold time (#47B) for both of
// them is met for the same falling edge of the processor clock", so every task
// below drives them from a rising edge.
logic berr_drv;   // active high here; inverted onto the pin
logic avec_drv;   // likewise. Held on across ordinary cycles to prove it is ignored.
logic halt_drv;
logic br_drv;
logic bgack_drv;
logic dbf_drv;

// The three-state data bus.
wire [31:0] dbus;
assign dbus = d_oe ? d_o : 32'bz;

// What the pins look like to a device: an output the core is not driving is z.
wire [31:0] a_pin   = a_oe   ? a_o   : 32'bz;
wire  [1:0] siz_pin = siz_oe ? siz_o : 2'bz;
wire  [2:0] fc_pin  = fc_oe  ? fc_o  : 3'bz;
wire        as_pin  = as_oe  ? as_n_o : 1'bz;
wire        ds_pin  = ds_oe  ? ds_n_o : 1'bz;
wire        rw_pin  = rw_oe  ? rw_o   : 1'bz;

rd68021_biu dut (
    .clk (clk), .rst_n (rst_n),
    .req_valid (req_valid), .req_kind (req_kind), .req_fc (req_fc),
    .req_addr (req_addr), .req_bytes (req_bytes), .req_wdata (req_wdata),
    .req_rmc (req_rmc), .req_cpuspace (req_cpuspace), .req_cpuaddr (req_cpuaddr),
    .req_ack (req_ack), .req_last (req_last), .req_rdata (req_rdata),
    .req_end (req_end), .req_fault (req_fault), .req_fault_wr (req_fault_wr),
    .req_dsack (req_dsack),
    .flt_addr (flt_addr), .flt_bytes (flt_bytes), .flt_fc (flt_fc),
    .flt_rw (flt_rw), .flt_rmc (flt_rmc), .flt_dob (flt_dob), .flt_dib (flt_dib),
    .rst_op_valid (1'b0), .rst_addr (32'd0), .rst_bytes (3'd0), .rst_fc (3'd0),
    .rst_rw (1'b1), .rst_rmc (1'b0), .rst_dob (32'd0),
    .fetch_valid (fetch_valid), .fetch_addr (fetch_addr), .fetch_fc (fetch_fc),
    .fetch_ack (fetch_ack), .fetch_last (fetch_last), .fetch_rdata (fetch_rdata),
    .fetch_fault (fetch_fault), .bus_abort (1'b0),
    .reset_req (1'b0), .reset_busy (reset_busy), .dbf (dbf_drv),
    .ipl_sync_n (ipl_sync_n), .reset_sync_n (reset_sync_n),
    .halt_sync_n (halt_sync_n), .cdis_sync_n (cdis_sync_n),
    .bus_idle (bus_idle), .bus_granted (bus_granted),
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
    .ipl_n_i (3'b111), .avec_n_i (~avec_drv),
    .br_n_i (~br_drv), .bg_n_o (bg_n_o), .bgack_n_i (~bgack_drv),
    .berr_n_i (~berr_drv),
    .reset_n_i (1'b1), .reset_n_o (reset_n_o), .reset_n_oe (reset_n_oe),
    .halt_n_i (~halt_drv), .halt_n_o (halt_n_o), .halt_n_oe (halt_n_oe),
    .cdis_n_i (1'b1)
);

// ---------------------------------------------------------------------------
// Slaves
// ---------------------------------------------------------------------------
logic [1:0] dsack32, dsack16, dsack8, dsackw;
wire [31:0] d32, d16, d8, dw;
logic       oe32, oe16, oe8, oew;

assign dbus = oe32 ? d32 : 32'bz;
assign dbus = oe16 ? d16 : 32'bz;
assign dbus = oe8  ? d8  : 32'bz;
assign dbus = oew  ? dw  : 32'bz;

assign dsack_n_i = dsack32 & dsack16 & dsack8 & dsackw;

rd68021_slave #(.PORT_BYTES (4), .WAITS (0), .BASE (32'h0000_0000),
                .MASK (32'hF000_0000)) s32 (
    .clk (clk), .rst_n (rst_n), .a_i (a_o), .siz_i (siz_o), .fc_i (fc_o),
    .as_n_i (as_n_o), .ds_n_i (ds_n_o), .rw_i (rw_o), .d_i (dbus), .wr_inhibit_i (1'b0),
    .d_o (d32), .d_oe (oe32), .dsack_n_o (dsack32));

rd68021_slave #(.PORT_BYTES (2), .WAITS (0), .BASE (32'h1000_0000),
                .MASK (32'hF000_0000)) s16 (
    .clk (clk), .rst_n (rst_n), .a_i (a_o), .siz_i (siz_o), .fc_i (fc_o),
    .as_n_i (as_n_o), .ds_n_i (ds_n_o), .rw_i (rw_o), .d_i (dbus), .wr_inhibit_i (1'b0),
    .d_o (d16), .d_oe (oe16), .dsack_n_o (dsack16));

rd68021_slave #(.PORT_BYTES (1), .WAITS (0), .BASE (32'h2000_0000),
                .MASK (32'hF000_0000)) s8 (
    .clk (clk), .rst_n (rst_n), .a_i (a_o), .siz_i (siz_o), .fc_i (fc_o),
    .as_n_i (as_n_o), .ds_n_i (ds_n_o), .rw_i (rw_o), .d_i (dbus), .wr_inhibit_i (1'b0),
    .d_o (d8), .d_oe (oe8), .dsack_n_o (dsack8));

rd68021_slave #(.PORT_BYTES (4), .WAITS (3), .BASE (32'h3000_0000),
                .MASK (32'hF000_0000)) sw (
    .clk (clk), .rst_n (rst_n), .a_i (a_o), .siz_i (siz_o), .fc_i (fc_o),
    .as_n_i (as_n_o), .ds_n_i (ds_n_o), .rw_i (rw_o), .d_i (dbus), .wr_inhibit_i (1'b0),
    .d_o (dw), .d_oe (oew), .dsack_n_o (dsackw));

// ---------------------------------------------------------------------------
// Clock, reset, bookkeeping
// ---------------------------------------------------------------------------
initial begin
  if (!$value$plusargs("period=%f", CLK_PERIOD)) CLK_PERIOD = 60.0;
  clk = 1'b0;
  forever #(CLK_PERIOD/2.0) clk = ~clk;
end

int unsigned as_count;
int unsigned ocs_count;
int unsigned fails;
int unsigned checks;

initial begin
  as_count  = 0;
  ocs_count = 0;
  fails     = 0;
  checks    = 0;
end

// One AS assertion is one bus cycle; one OCS assertion is one operand.
always @(negedge as_n_o)  if (rst_n) as_count  = as_count + 1;
always @(negedge ocs_n_o) if (rst_n) ocs_count = ocs_count + 1;

task automatic reset_dut();
  rst_n        = 1'b0;
  pending      = 1'b0;
  req_kind     = 3'd0;
  req_fc       = 3'b101;
  req_addr     = 32'd0;
  req_bytes    = 3'd0;
  req_wdata    = 40'd0;
  req_rmc      = 1'b0;
  req_cpuspace = 4'd0;
  req_cpuaddr  = 8'd0;
  fetch_pending = 1'b0;
  berr_drv     = 1'b0;
  avec_drv     = 1'b0;
  halt_drv     = 1'b0;
  br_drv       = 1'b0;
  bgack_drv    = 1'b0;
  dbf_drv      = 1'b0;
  fetch_addr   = 32'd0;
  fetch_fc     = 3'b110;
  repeat (4) @(posedge clk);
  rst_n = 1'b1;
  repeat (2) @(posedge clk);
endtask

task automatic check(input bit ok, input string what);
  checks = checks + 1;
  if (!ok) begin
    fails = fails + 1;
    $display("  FAIL: %s", what);
  end
endtask

// ---------------------------------------------------------------------------
// Operand requests
// ---------------------------------------------------------------------------
task automatic op_read(input logic [31:0] addr, input int nbytes,
                       output logic [39:0] data, output int unsigned cycles);
  int unsigned c0;
  @(negedge clk);
  c0        = as_count;
  req_kind  = 3'd0;                     // CT_READ
  req_addr  = addr;
  req_bytes = nbytes[2:0];
  req_wdata = 40'd0;
  pending   = 1'b1;
  @(posedge req_ack);
  pending   = 1'b0;
  data      = req_rdata;
  cycles    = as_count - c0;
  @(negedge clk);
endtask

task automatic op_write(input logic [31:0] addr, input int nbytes,
                        input logic [39:0] data, output int unsigned cycles);
  int unsigned c0;
  @(negedge clk);
  c0        = as_count;
  req_kind  = 3'd1;                     // CT_WRITE
  req_addr  = addr;
  req_bytes = nbytes[2:0];
  req_wdata = data;
  pending   = 1'b1;
  @(posedge req_ack);
  pending   = 1'b0;
  cycles    = as_count - c0;
  @(negedge clk);
endtask

task automatic op_fetch(input logic [31:0] addr,
                        output logic [31:0] data, output int unsigned cycles);
  int unsigned c0;
  @(negedge clk);
  c0          = as_count;
  fetch_addr    = addr;
  fetch_pending = 1'b1;
  @(posedge fetch_ack);
  fetch_pending = 1'b0;
  data        = fetch_rdata;
  cycles      = as_count - c0;
  @(negedge clk);
endtask

// ---------------------------------------------------------------------------
// Bus exception injection
//
// Table 5-8 indexes its two samples by "the number of the current even bus
// state": n is S2, whose rising edge is one clock after AS asserts, and n+2 is
// S4. These two tasks put a signal exactly there.
// ---------------------------------------------------------------------------
task automatic assert_at_n(input bit berr, input bit halt);
  @(negedge as_n_o);      // the falling edge that enters S1
  @(posedge clk);         // the rising edge that enters S2 -- state n
  berr_drv = berr;
  halt_drv = halt;
endtask

task automatic assert_at_n2(input bit berr, input bit halt);
  @(negedge as_n_o);
  @(posedge clk);         // S2
  @(posedge clk);         // S4 -- state n+2
  berr_drv = berr;
  halt_drv = halt;
endtask

task automatic release_exc();
  @(posedge clk);
  berr_drv = 1'b0;
  halt_drv = 1'b0;
endtask

// ---------------------------------------------------------------------------
// Two standing properties, checked on every clock edge for the whole run.
//
// The first: the core must never drive AS low while the address bus is released.
//
// The second is the one that matters here, and it took a wrong first attempt to
// find. The MC68010 project's hardest arbitration bug was that the bus state
// machine decided whether to START a cycle from the arbiter's CURRENT state while
// the output enables followed its NEXT one, so on the single edge where the
// arbiter reached its granting state a cycle began anyway -- and then ran with
// its buses in high impedance. In THIS design that cycle does not drive AS
// either, because as_oe follows the same release; so a monitor that looks for
// "AS low and the address released" never fires. What is externally observable
// is that the cycle SILENTLY VANISHES: no slave sees it, nothing answers, and
// the operand either hangs or comes back wrong. bus_arb_tb sweeps the phase of
// BR across a multi-cycle operand to make that happen.
//
// Kept anyway, because it costs nothing and covers the other shape of the bug.
// ---------------------------------------------------------------------------
int unsigned drive_violations;
initial drive_violations = 0;

always @(posedge clk or negedge clk) begin
  if (rst_n && as_oe && !as_n_o && !a_oe) begin
    drive_violations = drive_violations + 1;
    $display("  FAIL: AS asserted at %0t with the address bus released", $time);
  end
  // A cycle that begins while the bus is being handed over drives nothing at
  // all. ECS marks the beginning of every bus cycle and is never three-stated,
  // so it is visible even then.
  if (rst_n && !ecs_n_o && bus_granted) begin
    drive_violations = drive_violations + 1;
    $display("  FAIL: a bus cycle began at %0t with the bus relinquished", $time);
  end
end
