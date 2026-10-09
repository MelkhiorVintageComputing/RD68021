# RD68021 pinout

Derived from **Table 3-1, Signal Index** and §3.2–3.11 of
`Inputs/doc/MC68030_Doc_More_Readable/MC68020UM_split/07-section-03-signal-description.pdf`.
Figure 3-1 is the MC68020 signal set; this design implements the MC68020, not the
MC68EC020, so `ECS`, `OCS`, `DBEN`, `RMC`, `BGACK`, `IPEND` and `CDIS` are all present and
the address bus is 32 bits.

The original has three-state and bidirectional pins. This core has none: every such pin is
split into an input `_i`, an output `_o` and an output-enable `_oe`. An external wrapper
recombines them:

```systemverilog
assign pad = core_oe ? core_o : 1'bz;   // three-state pin
assign core_i = pad;
assign pad = core_oe ? 1'b0 : 1'bz;     // open-drain pin (RESET, HALT)
```

`_oe` is **active high — asserted means the core is driving**. Active-low signals keep the
`_n` suffix and are active-low *on the pin*, so `as_n_o == 0` means AS asserted.

## Port list

### Clock

| Port | Dir | Notes |
|---|---|---|
| `clk` | in | Free-running. Both edges are used: one bus state S0–S5 per half period, so a bus cycle with no wait states is three clocks. |
| `rst_n` | in | **Not an MC68020 pin.** Asynchronous power-on initialisation, so that every register has a defined value without power-on state, after which the processor runs reset exception processing. The architectural reset is `reset_n_i` below; `rst_n` resets everything it does and more -- the registers UM 6.1.1 leaves alone, the arbiter, and the RESET instruction's own counter, which the pin cannot reset because that counter drives it (`doc/divergences.md`, "The two resets"). |

### Function codes (§3.2)

| Port | Dir | Notes |
|---|---|---|
| `fc_o[2:0]` | out | Table 2-1's eight address spaces. Valid while AS is asserted. `MOVES` drives them from SFC/DFC, so all eight encodings — including the three reserved ones — can appear. |
| `fc_oe` | out | |

### Address bus (§3.3)

| Port | Dir | Notes |
|---|---|---|
| `a_o[31:0]` | out | A1 and A0 are real pins: byte selection is by `A1`, `A0`, `SIZ1`, `SIZ0` and the port size, not by separate data strobes. In CPU space the address is synthesised — figure 5-31. |
| `a_oe` | out | |

### Data bus (§3.4)

| Port | Dir | Notes |
|---|---|---|
| `d_i[31:0]` | in | Latched on the falling edge entering S5. |
| `d_o[31:0]` | out | **All 32 bits are driven on every write**, duplicated across the lanes per Table 5-7, "because at the beginning of a write cycle the bus controller does not know the port size" (§5.2.4). |
| `d_oe` | out | |

### Transfer size (§3.5)

| Port | Dir | Notes |
|---|---|---|
| `siz_o[1:0]` | out | The number of bytes **remaining** to be transferred, not the size of the operand — so they change as a multi-cycle transfer proceeds. Table 5-2. |
| `siz_oe` | out | |

### Asynchronous bus control (§3.6)

| Port | Dir | Notes |
|---|---|---|
| `ecs_n_o` | out | External cycle start: one half clock at the beginning of **every** bus cycle. Never three-stated. |
| `ocs_n_o` | out | Operand cycle start: identical, but only for the **first** bus cycle of an operand transfer — so it is driven from the request handshake, not from the cycle. Never three-stated. |
| `rw_o`, `rw_oe` | out | High = read, low = write. |
| `rmc_n_o`, `rmc_oe` | out | Asserted across every bus cycle of a read-modify-write, and inhibits `BG` absolutely while it is up. |
| `as_n_o`, `as_oe` | out | Asserted half a clock after the cycle begins — which is the window in which a cache hit may abort the cycle (§5.2.5). |
| `ds_n_o`, `ds_oe` | out | One strobe, not the MC68010's UDS/LDS pair. |
| `dben_n_o`, `dben_oe` | out | Data buffer enable, active low (UM table 3-2). Not called three-state in §3.6, but specification 16 measures "Clock High to AS, DS, R/W, DBEN High Impedance" — see `doc/manual-contradictions.md`. |
| `dsack_n_i[1:0]` | in | `[1]` is DSACK1. Sampled at the falling edge entering S3, and **both bits must be captured by the same flop pair on the same edge** and decoded afterwards: specification 31A allows 15 ns of skew between them at 16.67 MHz, and sampling them independently lets a 32-bit port present transiently as 8-bit. |

### Interrupt control (§3.7)

| Port | Dir | Notes |
|---|---|---|
| `ipl_n_i[2:0]` | in | Encoded level, active low; `ipl_n_i[2]` is the most significant. Synchronised internally. |
| `ipend_n_o` | out | An interrupt above the mask has been recognised internally. Never three-stated. |
| `avec_n_i` | in | Requests an autovector during an interrupt acknowledge cycle; ignored in every other cycle. There is no VPA and no E clock — the M6800 interface is gone. |

### Bus arbitration (§3.8)

| Port | Dir | Notes |
|---|---|---|
| `br_n_i` | in | Bus request. |
| `bg_n_o` | out | Bus grant. Never three-stated — no `_oe`. |
| `bgack_n_i` | in | Bus grant acknowledge. Three-wire arbitration, figure 5-44. |

### Bus exception control (§3.9)

| Port | Dir | Notes |
|---|---|---|
| `berr_n_i` | in | Bus error. With HALT, selects retry rather than exception. |
| `reset_n_i` | in | External reset input, the pin as the processor sees it, wired with `reset_n_oe` as the open-drain pin is. Unlike the MC68000 and MC68010 it does **not** need HALT asserted with it. Ignored while the RESET instruction drives the pin and for four clocks after (UM 5.8). |
| `reset_n_o`, `reset_n_oe` | out | Open drain. `reset_n_o` is constant 0; the `RESET` instruction asserts `reset_n_oe` for **512 clocks** (§5.8) to reset peripherals without disturbing the core. |
| `halt_n_i` | in | Suspends bus activity at the end of the current cycle; with BERR, requests a retry. |
| `halt_n_o`, `halt_n_oe` | out | Open drain. `halt_n_o` is constant 0; driven on a double bus fault. |

### Emulator support (§3.10)

| Port | Dir | Notes |
|---|---|---|
| `cdis_n_i` | in | Statically disables the on-chip cache, whatever the E bit of CACR says. Synchronised internally. |

## Output-enable domains

§5.8: "During the reset period, the entire bus three-states (except for
non-three-statable signals, which are driven to their inactive state)." That, plus bus
relinquish, plus the release at the end of each cycle that specification 7 measures, gives
three groups:

| Enable | Covers | Negated when |
|---|---|---|
| `a_oe`, `d_oe`, `fc_oe`, `siz_oe`, `rmc_oe` | address, data, FC, SIZ, RMC | between bus cycles (spec 7, "Clock High to Address, Data, FC, Size, RMC High Impedance"), on bus relinquish, and while RESET is asserted |
| `as_oe`, `ds_oe`, `rw_oe`, `dben_oe` | AS, DS, R/W, DBEN | on bus relinquish and while RESET is asserted (spec 16) |
| `reset_n_oe`, `halt_n_oe` | RESET, HALT | open drain — asserted only to pull low |

`ecs_n_o`, `ocs_n_o`, `ipend_n_o` and `bg_n_o` have no enable; they are always driven.

`ADDR_HIZ_BETWEEN_CYCLES` is a parameter, as it was on the MC68010, for a board that needs
the address bus held between cycles. It changes only the first group's behaviour at the end
of a cycle, never on relinquish or reset.
