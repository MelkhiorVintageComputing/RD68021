// RD68021 - SystemVerilog MC68020
//
// The on-chip instruction cache -- UM section 4.
//
// "A direct-mapped cache of 64 long-word entries. Each cache entry consists of a
// tag field (A31-A8 and FC2), one valid bit, and 32 bits (two words) of
// instruction data" (UM 4.1). The index is A7-A2, and A1 picks the word, which is
// the cache holding register's business rather than this module's: a lookup here
// answers with the whole long word.
//
// ENTRIES is a power of two from 2 to 64. Fewer entries means a narrower index and
// a correspondingly wider tag, so the cache is smaller and never wrong. 64 is the
// MC68020; the others are here because an FPGA build may want the area back.
// ENTRIES = 0 -- no cache at all -- is the IFU's decision and never instantiates
// this module.
//
// Reset. The array is a RAM and is NOT reset -- no flop in it, and nothing reads
// it unqualified. The valid bits are 64 ordinary flip-flops with an asynchronous
// reset, and they are the whole of "during processor reset, the cache is cleared
// by resetting all of the valid bits" (UM 4.2). A lookup of an entry whose valid
// bit is clear never looks at the tag or the data, so what the RAM powered up
// holding is unobservable.
//
// The read is asynchronous. 64 x 57 bits is distributed RAM on the FPGAs this
// targets (one LUT per bit on a 7-series part), so the lookup costs no clock and
// the hit is a tag compare on the output: the IFU can decide between the cache
// and the bus in the same clock it learns which long word it wants.

module rd68021_icache #(
    parameter int ENTRIES = 64
) (
    input  logic        clk,
    input  logic        rst_n,

    // Lookup: the long word at {la, 2'b00} in supervisor (fc2) or user program
    // space. Combinational.
    input  logic [29:0] la,
    input  logic        lfc2,
    output logic        hit,
    output logic [31:0] rdata,

    // Fill after a miss -- UM 4.1, "this new instruction is automatically written
    // into the cache entry, and the valid bit is set".
    input  logic        fill,
    input  logic [29:0] fa,
    input  logic        ffc2,
    input  logic [31:0] fdata,

    // Invalidation -- UM 4.3.1, CACR's C and CE bits. `inv_one` clears the entry
    // `inv_la` names, which is CAAR's index field.
    input  logic        inv_all,
    input  logic        inv_one,
    input  logic [29:0] inv_la
);

  localparam int IW = $clog2(ENTRIES);   // index width: A(IW+1)-A2
  localparam int TW = 30 - IW + 1;       // tag width: A31-A(IW+2), and FC2

  logic [TW+31:0] mem [0:ENTRIES-1];     // {tag, data}
  logic [ENTRIES-1:0] valid_q;

  logic [IW-1:0] lidx, fidx, iidx;
  logic [TW-1:0] ltag, ftag;

  assign lidx = la[IW-1:0];
  assign fidx = fa[IW-1:0];
  assign iidx = inv_la[IW-1:0];
  assign ltag = {la[29:IW], lfc2};
  assign ftag = {fa[29:IW], ffc2};

  // The array: written on the rising edge, read without one.
  always_ff @(posedge clk) begin
    if (fill) mem[fidx] <= {ftag, fdata};
  end

  logic [TW+31:0] entry;
  assign entry = mem[lidx];
  assign hit   = valid_q[lidx] && (entry[TW+31:32] == ltag);
  assign rdata = entry[31:0];

  // The valid bits. An invalidation in the same clock as a fill wins, whichever
  // entry the fill was for when the invalidation is of all of them: MOVEC setting
  // C means "every instruction the cache holds from before this is suspect", and a
  // long word read from memory before the MOVEC finished is one of them.
  //
  // Written as a whole-vector update rather than as `valid_q[fidx] <= 1'b1`: an
  // indexed write inside an asynchronously reset block makes yosys stage the
  // index and a lookahead copy of the whole vector in registers of their own,
  // 76 flops that are dead but that `make audit` counts.
  localparam logic [ENTRIES-1:0] ONE = {{(ENTRIES-1){1'b0}}, 1'b1};

  logic [ENTRIES-1:0] set_m, clr_m;
  assign set_m = fill    ? (ONE << fidx) : '0;
  assign clr_m = inv_one ? (ONE << iidx) : '0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)       valid_q <= '0;
    else if (inv_all) valid_q <= '0;
    else              valid_q <= (valid_q | set_m) & ~clr_m;
  end

  // CAAR is a whole address, and only its index field names an entry (UM 4.3.2).
  logic unused_icache;
  assign unused_icache = &{1'b1, inv_la[29:IW]};

endmodule
