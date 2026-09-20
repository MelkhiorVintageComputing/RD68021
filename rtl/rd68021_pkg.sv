// RD68021 - SystemVerilog MC68020
//
// Architectural constants, transcribed from the manual. Nothing here is a design
// decision; everything is a number the MC68020 already has, with the citation that
// fixes it.
//
// Referred to with full scope everywhere -- rd68021_pkg::FC_CPU -- because yosys 0.52
// supports no form of `import`. See doc/coding-standard.md.

`ifndef RD68021_PKG_SV
`define RD68021_PKG_SV

package rd68021_pkg;

  // ==========================================================================
  // Address spaces -- UM Table 2-1
  // ==========================================================================
  localparam logic [2:0] FC_RESERVED_0  = 3'b000;  // undefined, reserved
  localparam logic [2:0] FC_USER_DATA   = 3'b001;
  localparam logic [2:0] FC_USER_PROG   = 3'b010;
  localparam logic [2:0] FC_RESERVED_3  = 3'b011;  // undefined, reserved
  localparam logic [2:0] FC_RESERVED_4  = 3'b100;  // undefined, reserved
  localparam logic [2:0] FC_SUPER_DATA  = 3'b101;
  localparam logic [2:0] FC_SUPER_PROG  = 3'b110;
  localparam logic [2:0] FC_CPU         = 3'b111;

  // MOVES drives the function code from SFC/DFC, so all eight encodings -- including
  // the three reserved ones -- can appear on the pins.

  // ==========================================================================
  // CPU space types -- UM Figure 5-31, encoded on A19-A16 when FC = FC_CPU
  // ==========================================================================
  localparam logic [3:0] CPUS_BKPT      = 4'h0;  // breakpoint acknowledge
  localparam logic [3:0] CPUS_ACCESS    = 4'h1;  // access level control (CALLM/RTM)
  localparam logic [3:0] CPUS_COPROC    = 4'h2;  // coprocessor communication
  localparam logic [3:0] CPUS_IACK      = 4'hF;  // interrupt acknowledge

  // ==========================================================================
  // Transfer size -- UM Table 5-2
  //
  // SIZ1/SIZ0 are the number of bytes REMAINING to be transferred (UM 5.1.1), not
  // the size of the original operand, so a multi-cycle transfer changes them as it
  // goes. The encoding is simply the count modulo four.
  // ==========================================================================
  localparam logic [1:0] SIZ_LONG  = 2'b00;
  localparam logic [1:0] SIZ_BYTE  = 2'b01;
  localparam logic [1:0] SIZ_WORD  = 2'b10;
  localparam logic [1:0] SIZ_3BYTE = 2'b11;

  // The request interface counts bytes rather than encoding SIZ, because a bit-field
  // operand can span five bytes and SIZ cannot say so. The BIU converts.
  localparam int unsigned REQ_BYTES_W = 3;
  localparam logic [2:0]  BYTES_MAX   = 3'd5;

  // Operand size as the instruction set means it.
  typedef enum logic [1:0] { SZ_BYTE, SZ_WORD, SZ_LONG, SZ_3BYTE } opsize_e;

  // ==========================================================================
  // Port size reported by DSACK1/DSACK0 -- UM Table 5-1
  //
  // The pins are active low. These are the values of {dsack_n_i[1], dsack_n_i[0]}
  // sampled at the falling edge entering S3; both must be captured by the same flop
  // pair on the same edge and decoded afterwards, because specification 31A allows
  // 15 ns of skew between them at 16.67 MHz.
  // ==========================================================================
  localparam logic [1:0] DSACK_WAIT = 2'b11;  // neither asserted: insert wait states
  localparam logic [1:0] DSACK_8    = 2'b10;  // DSACK0 only: 8-bit port
  localparam logic [1:0] DSACK_16   = 2'b01;  // DSACK1 only: 16-bit port
  localparam logic [1:0] DSACK_32   = 2'b00;  // both: 32-bit port

  typedef enum logic [1:0] { PORT_8, PORT_16, PORT_32 } port_size_e;

  // ==========================================================================
  // Bus states -- UM 5.3, one state per CLK half period
  //
  // Even states begin on a rising edge, odd states on a falling edge, so a bus cycle
  // with no wait states is three clocks. ST_WH/ST_WL are the wait pair inserted
  // between S3 and S4; the rest are not the manual's states but this design's, and
  // are named so.
  // ==========================================================================
  typedef enum logic [3:0] {
    ST_S0, ST_S1, ST_S2, ST_S3, ST_S4, ST_S5,
    ST_WH, ST_WL,          // wait: one whole clock, re-sampling at ST_WL
    ST_IDLE,               // no cycle in progress
    ST_HALT,               // HALT asserted, bus released at the end of the cycle
    ST_ARB,                // bus granted to another master
    ST_RETRY               // BERR+HALT: wait for both to negate, then rerun
  } bus_state_e;

  // ==========================================================================
  // Cycle kinds and terminations
  // ==========================================================================
  typedef enum logic [2:0] {
    CT_READ,     // data read
    CT_WRITE,    // data write
    CT_IFETCH,   // instruction prefetch: always a long word from a long-word address
    CT_IACK,     // interrupt acknowledge, CPU space $F
    CT_BKPT,     // breakpoint acknowledge, CPU space $0
    CT_CPU       // other CPU-space access: coprocessor ($2), access level ($1)
  } cycle_kind_e;

  // There is no CT_RMW. UM 5.5.2 retries each read and each write of a
  // read-modify-write separately with RMC held throughout, so RMC is a qualifier
  // across a run of ordinary cycles rather than one indivisible cycle -- which is
  // also the only way CAS2's four transfers are expressible.

  typedef enum logic [2:0] {
    CE_NONE,     // no cycle
    CE_DSACK,    // normal termination
    CE_BERR,     // bus error
    CE_RETRY,    // BERR + HALT
    CE_AVEC,     // autovector, interrupt acknowledge only
    CE_HALT      // HALT at or before DSACK: cycle completed, then halted
  } cycle_end_e;

  // ==========================================================================
  // Status register -- UM Figure 1-4
  // ==========================================================================
  localparam int SR_C  = 0;
  localparam int SR_V  = 1;
  localparam int SR_Z  = 2;
  localparam int SR_N  = 3;
  localparam int SR_X  = 4;
  localparam int SR_I0 = 8;   // I2-I0 are bits 10:8
  localparam int SR_M  = 12;  // master/interrupt mode: selects MSP or ISP
  localparam int SR_S  = 13;
  localparam int SR_T0 = 14;  // trace on change of flow
  localparam int SR_T1 = 15;  // trace on any instruction

  // Bits 11, 7, 6 and 5 read as zero and are ignored when written.
  localparam logic [15:0] SR_IMPLEMENTED = 16'b1111_0111_0001_1111;

  // Reset leaves the processor in the interrupt mode of the supervisor level with the
  // mask at 7 (UM 2.1.1: "the processor is in this mode after a reset operation").
  localparam logic [15:0] SR_RESET = 16'h2700;

  // ==========================================================================
  // Exception stack frames -- UM Table 6-5
  // ==========================================================================
  localparam logic [3:0] FMT_SHORT     = 4'h0;  // four words
  localparam logic [3:0] FMT_THROWAWAY = 4'h1;  // four words, interrupt stack switch
  localparam logic [3:0] FMT_SIX       = 4'h2;  // six words
  localparam logic [3:0] FMT_COPROC    = 4'h9;  // ten words, coprocessor midinstruction
  localparam logic [3:0] FMT_FAULT_S   = 4'hA;  // sixteen words, short bus fault
  localparam logic [3:0] FMT_FAULT_L   = 4'hB;  // forty-six words, long bus fault

  localparam int FRAME_WORDS_SHORT     = 4;
  localparam int FRAME_WORDS_THROWAWAY = 4;
  localparam int FRAME_WORDS_SIX       = 6;
  localparam int FRAME_WORDS_COPROC    = 10;
  localparam int FRAME_WORDS_FAULT_S   = 16;
  localparam int FRAME_WORDS_FAULT_L   = 46;

  // UM 6.1.12: RTE compares the version number in bits 15-12 of the word at SP+$36 of
  // a long frame against its own, and takes a format error if they differ. That is
  // what makes this design's private encoding of the internal words legitimate, and
  // it is also why format $A -- which has no version field -- may carry no private
  // state. See doc/manual-contradictions.md for why the offset is $36 and not $38.
  localparam int         FRAME_VERSION_OFF = 'h36;
  localparam logic [3:0] FRAME_VERSION     = 4'h1;

  // ==========================================================================
  // Special status word -- UM Figure 6-8, at offset $0A of both fault frames
  // ==========================================================================
  localparam int SSW_FC   = 15;  // fault on stage C
  localparam int SSW_FB   = 14;  // fault on stage B
  localparam int SSW_RC   = 13;  // rerun stage C prefetch
  localparam int SSW_RB   = 12;  // rerun stage B prefetch
  localparam int SSW_DF   = 8;   // data fault / rerun the data access
  localparam int SSW_RM   = 7;   // the data cycle was part of a read-modify-write
  localparam int SSW_RW   = 6;   // 1 = read, 0 = write
  localparam int SSW_SIZE = 4;   // SIZE is bits 5:4
  // Bits 2:0 are the function code of the data cycle; bits 11:9 and 3 are reserved.

  // UM 6.2.2: "The only bits in the SSW that may be modified are DF, RB, and RC."
  localparam logic [15:0] SSW_HANDLER_MASK = (16'b1 << SSW_DF)
                                           | (16'b1 << SSW_RB)
                                           | (16'b1 << SSW_RC);

  // ==========================================================================
  // Vector numbers -- PRM Appendix B
  // ==========================================================================
  localparam logic [7:0] VEC_RESET_ISP    = 8'd0;
  localparam logic [7:0] VEC_RESET_PC     = 8'd1;
  localparam logic [7:0] VEC_ACCESS_FAULT = 8'd2;   // bus error
  localparam logic [7:0] VEC_ADDRESS_ERR  = 8'd3;
  localparam logic [7:0] VEC_ILLEGAL      = 8'd4;
  localparam logic [7:0] VEC_DIV_ZERO     = 8'd5;
  localparam logic [7:0] VEC_CHK          = 8'd6;   // CHK, CHK2
  localparam logic [7:0] VEC_TRAPCC       = 8'd7;   // TRAPcc, TRAPV, cpTRAPcc
  localparam logic [7:0] VEC_PRIVILEGE    = 8'd8;
  localparam logic [7:0] VEC_TRACE        = 8'd9;
  localparam logic [7:0] VEC_LINE_A       = 8'd10;
  localparam logic [7:0] VEC_LINE_F       = 8'd11;
  localparam logic [7:0] VEC_COPROC_PROTO = 8'd13;
  localparam logic [7:0] VEC_FORMAT_ERR   = 8'd14;
  localparam logic [7:0] VEC_UNINIT_INT   = 8'd15;
  localparam logic [7:0] VEC_SPURIOUS     = 8'd24;
  localparam logic [7:0] VEC_AUTOVEC_1    = 8'd25;  // levels 1-7 are 25-31
  localparam logic [7:0] VEC_TRAP_0       = 8'd32;  // TRAP #n is 32 + n

  // ==========================================================================
  // Instruction cache -- UM 4.1
  //
  // 64 direct-mapped long-word entries. The tag is A31-A8 plus FC2, so a supervisor
  // and a user fetch of the same address are different entries; A7-A2 index; A1
  // selects the word within the entry.
  // ==========================================================================
  localparam int ICACHE_INDEX_W = 6;
  localparam int ICACHE_TAG_W   = 25;  // A31-A8 and FC2

  // CACR -- UM Figure 4-2. Bits 31-4 read as zero and are ignored when written.
  localparam int CACR_E  = 0;  // enable
  localparam int CACR_F  = 1;  // freeze: a miss does not replace
  localparam int CACR_CE = 2;  // clear the entry CAAR names; always reads zero
  localparam int CACR_C  = 3;  // clear all entries; always reads zero
  localparam logic [31:0] CACR_IMPLEMENTED = 32'h0000_0003;  // only E and F are stored

  // ==========================================================================
  // RESET -- UM 5.8
  // ==========================================================================
  localparam int RESET_INSN_CLKS = 512;  // the RESET instruction drives the pin this long

endpackage

`endif
