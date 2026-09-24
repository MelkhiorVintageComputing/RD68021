# A whole machine: the Sun-3/160 on the RTL core

`make sun3` boots a real Sun-3/160 boot PROM -- the Carrera, ROM Rev 3.0 -- with
the RTL core as the machine's CPU, and requires the console output to be byte for
byte what the same machine prints with an emulated MC68020, up to the monitor's
`>` prompt.

```
  EEPROM: Using RS232 A port.
  Selftest Completed.
  Sun Workstation, Model Sun-3/160M.
  ROM Rev 3.0, 4MB memory installed, Serial #65957.
  Ethernet address 8:0:20:11:22:33, Host ID 110101A5.
  Testing 0 Megabytes of Memory ... Completed.
  Auto-boot in progress...
  EEPROM boot device...Boot: sd(0,0,0)
  Device not found
  >
```

About 71 million clocks of the core, a little over a minute of simulation.

## How

The machine is TME, The Machine Emulator, from
`Inputs/ref/Run-Sun3-SunOS-4.1.1/tme-0.8_up`. TME builds a machine out of
elements joined by bus connections, and a CPU is an element like any other: the
machine description says `cpu0 at mainbus0: tme/ic/m68020`. So the core goes in as
one more CPU element, `tme/ic/rd68021`, offering the Sun-3 board exactly the
connection TME's own 68020 offers. Everything on the far side of it is TME's:
the Sun-3 MMU, control space, the interrupt register, the memory, the serial
chips, the clock.

| | |
|---|---|
| `sim/tme/rd68021_model.cpp` | the Verilator model of `rd68021_top` behind a C interface: a half clock, a pin |
| `sim/tme/rd68021.c` | the TME element: the core clocked, and every bus cycle answered |
| `sim/tme/build.sh` | TME copied to `build/tme` (Inputs/ is immutable), the element added, `tmesh` linked with the model |
| `sim/tme/SUN3.in` | the machine, headless: console on the first serial port, no framebuffer, keyboard or FPU |
| `tools/sun3_rom.py` | the PROM, copied and patched to skip a display wait |

**A bus cycle** is answered on the rising edge after the core asserts AS, as the
testbenches' memory models answer it. The element looks the address up through
the board's TLB filler by function code -- which is where the Sun-3 MMU is, as it
is on the real board -- and either reads or writes emulator memory directly or
runs a TME bus cycle through the device, routed with TME's own MC68020 byte-lane
table (UM table 5-5). How many bytes the responder took is turned back into the
DSACK encoding that says so; a fault is BERR.

**An interrupt acknowledge** asks the board for the vector: a vector comes back
on an eight-bit port, "no vector" as AVEC, and no interrupt at all as BERR, which
the core takes as spurious (UM 5.4.1). Any other CPU-space cycle -- a breakpoint,
an access-level check, a coprocessor -- is BERR: there is nothing there.

**TME's threads** are cooperative and leave by longjmp, and a thread's function is
called afresh at every dispatch. So the element runs the core two thousand clocks
at a time and yields, keeping everything in the element and calling the C++
model only through functions that return.

**The TLB** is 64 entries for program space and 64 for the rest, long-lived and
invalidated by the board through TME's tokens. It has to be: TME's Sun-3 memory
parity test follows the one data entry involved in it and aborts if any other is
filled meanwhile, an instruction fetch included. A single entry refilled for every
cycle -- the first version -- aborted there.

**Stopping.** A monitor at its prompt waits for input forever. The element
samples the program counter every 64 clocks, and `RD68021_STOP_PC=0x0fef0f56` --
the monitor's character input -- stops the machine once it has been seen there a
thousand times. The same sample is a profile: the report in `rd68021.log` lists
the hottest sixteen-byte lines of the PROM.

## What the PROM found

In the order it found them, each now in `doc/bugs-found.md`:

1. **Every memory destination through an absolute-long or indexed address wrote
   the wrong thing.** The address routines used T0 and T1; the instructions held
   their operands there. `MOVES.B D1,$30000000` -- the PROM's context-register
   test -- ran as a read through SFC. Fixed by moving the routines to T2 and T3,
   `check_ea_live` in the microcode assembler, and the vector sweep gaining
   absolute-long and full-format destinations; the extended sweep fails 144 of the
   `moves` group's 504 vectors on the microcode before the fix.
2. **The static bit instructions lost their bit number on an indexed address**,
   the same bug through an implicit read of XW -- `BTST #2,(0,A0,D1.L*4)`, the
   PROM's test for a transmitter ready, tested bit 0.
3. **TST of an address register was an illegal instruction** -- the MC68020 allows
   it, and an immediate, and the MC68010 did not.

None of them showed in the per-opcode sweep, the co-simulated programs, the
effective-address vectors or the second core, and each is exactly the kind of
thing a real operating system's code does on its first page.

## What is not checked

- **Lockstep.** TME's 68020 and the core take different numbers of clocks, and
  TME's clock chip runs on host time, so the two machines take their interrupts at
  different instructions. What is compared is what the machine *does* -- the
  console -- not the instruction stream.
- **The FPU.** The machine has none until the coprocessor interface (M13); a
  floating-point instruction is an F-line trap, as on a Sun-3 with no 68881.
- **RMC.** The element does not pass the core's read-modify-write lock to TME's bus
  cycles. One CPU and no DMA master in this machine makes that unobservable.
- **Booting SunOS.** The PROM stops at "Device not found" because the machine has no
  disk. `Inputs/ref/Run-Sun3-SunOS-4.1.1` has the installation tapes; that is the
  next step, and it will need the SCSI controller back in the machine description.

## The PROM patch

`tools/sun3_rom.py` changes one word, the count of the wait after the PROM writes
the diagnostic LEDs, from 65535 to 2 -- the Sun-3/160 counterpart of
`Inputs/ref/VintageBusFPGA_Common/RomPatcher/Sun3_60FastBoot`, which does the same
to the Sun-3/60's v1.9 PROM -- and puts the checksum right. It refuses a PROM
whose bytes are not the ones it expects. The EEPROM image says 4 MB rather than 8,
which halves the time the PROM spends initialising memory; neither changes a byte
of what it prints.
