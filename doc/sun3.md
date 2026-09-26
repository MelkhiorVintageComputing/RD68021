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
## SunOS 4.1.1

`make sunos` runs the same machine with a SCSI controller (TME's `si` board; the
input's `sun-sc` is not found by this PROM), described in `sim/tme/SUNOS.in`, and
the first five files of the installation tape, with the EEPROM's boot device set
to the tape. The PROM boots
SunOS 4.1.1's install kernel (MUNIX) on the core -- kernel loaded, devices
probed, RAM disk read, root mounted -- to its install menu and a working
single-user shell, as on TME's m68020:

```
What would you like to do?
  1 - install SunOS mini-root
  2 - exit to single user shell
Enter a 1 or 2: 2
you may restart this script by typing <cntl-D>
# ls /
.MUNIXFS  README    bin       etc       lib       stand     usr
.profile  a         dev       extract   sbin      tmp
# echo hello from the rd68021
hello from the rd68021
#
```

`sim/tme/drive.sh` answers the menu and types the two commands, on both CPUs,
and the target requires the two consoles to be identical byte for byte, ending at
the shell's prompt -- about three minutes on the core. It found two more bugs, both in the bus-fault frames, and both in
`doc/bugs-found.md`:

4. **A bus fault taken in user mode stacked its status register in user space** --
   the Sun-3 MMU refused it, and the second fault halted the processor.
5. **A prefetch fault with the pipe empty resumed the previous instruction.** The
   kernel starts a forked child with an RTE to its first instruction, on a page
   the fork has not mapped yet. The child faulted, the kernel mapped the page and
   returned, and the core ran the kernel's own RTE -- still in stage D -- in user
   mode. The child died of a privilege violation and the install script never
   printed its menu. Stage D's valid bit is now in the frame, and every fault
   takes the long frame.

The second was found by looking, as the user suggested, at how the machine
answered page faults of newly forked processes: `RD68021_FAULTS` showed the
child's first address faulting and never being fetched again.

## An installed SunOS 4.1.1, from disk

`make sunos-disk` boots a disk image with the whole of SunOS 4.1.1 installed --
made by the unattended installer in `Run-Sun3-SunOS-4.1.1/diskimage`, not an input
(`SUNOS_IMG=` names it) -- on the installer's machine: TME's `sun-sc` SCSI board and
an ACB-4000 disk, `sim/tme/SUNOS-DISK.in`. The GENERIC kernel comes up from
`sd(0,0,0)`, checks both file systems, starts the daemons and reaches
`sun3 login:`; `drive.sh` logs in as root and types `uname -a`, `ls /` and `df`.
The console must be identical to TME's m68020 once the time stamps are masked --
about twelve minutes on the core, two billion clocks.

```
sun3 login: root
Last login: Thu Sep 24 15:30:31 on console
SunOS Release 4.1.1 (GENERIC) #1: Sat Oct 13 06:05:48 PDT 1990
sun3# uname -a
SunOS sun3 4.1.1 1 sun3
sun3# df
Filesystem            kbytes    used   avail capacity  Mounted on
/dev/sd0a              23815    2399   19034    11%    /
/dev/sd0g             232094  114647   94237    55%    /usr
```

It found one more, in the frames again:

6. **A prefetch fault resumed an instruction with the fault handler's working
   registers.** `/etc/rc` printed `Memory fault` where TME's m68020 printed
   nothing: `ps -U` died, and `/etc/psdatabase` was never rewritten. Its last
   system call and the shell's report bracketed a prefetch fault at the start of a
   page of the shared C library, and then a read of address $42. The last word of
   the page before was `MOVEA.L D7,A0`, whose final microword copies the source out
   of T0; the short frame does not carry T0, and the kernel's fault handler had
   reused it. Every fault now takes the long frame, and the `/etc/psdatabase` the
   core writes is byte for byte the one TME's m68020 writes.

## With an MC68881: `make sunos-fpu`

The same installed system on two machines that both have an MC68881 -- TME's m68020
with its own, the core with `sim/tme/rd68021_fpu.c` on its coprocessor interface --
compiling a C program with `cc -f68881` on the machine and running it. The consoles are
identical, time stamps aside, and the core's report shows what crossed the interface on
the way:

```
MC68881: 6057 CIR accesses, 852 general and 57 conditional instructions,
         644 saves, 645 restores; primitives read: $08xx 909 $81xx 17
         $95xx 60 $96xx 335 $A1xx 18 $B1xx 25 $B2xx 153
```

The saves and restores are the kernel's: SunOS switches the FPU's context with
FSAVE, FMOVEM and FRESTORE at every context switch once a process has used it.
`doc/coprocessor.md` has how the MC68881 is built and what it does not do.

## Time

TME's scheduler and the Sun-3's clock chip ran on host time, and the core runs
several times slower than a real 16.67 MHz MC68020, so every clock tick arrived after
a fraction of the instructions it should have. `sim/tme/build.sh` adds a hook to the
copy of TME -- `tme_gettimeofday` asks it, and the Intersil 7170 reads its time of day
through `tme_gettimeofday` -- and the element installs it: the time the machine was
made at, rounded to a second, plus 60 ns per clock. A clock tick then comes after as
many instructions as on the real machine. A run is reproducible up to the date it
starts on, which is the host's: two runs of the same RTL through `make sunos-fpu`
finished 0.13 % apart in clocks (1,864,128,103 and 1,866,615,375), date
conversion and whatever else reads the clock taking a different path. With no
hook, TME's own CPUs are unchanged.

## Instruments

All in `tme/ic/rd68021`, controlled by environment variables so that a normal run
pays nothing for them:

| | |
|---|---|
| `RD68021_STOP_AT`, `RD68021_STOP_PC` | stop at a clock, or once the PC has sat in a sixteen-byte line a thousand samples |
| `RD68021_LOG_FROM`/`_TO`, `RD68021_LOG_ADDR`, `RD68021_LOG_DEV_FROM` | every bus cycle in a clock window, in an address range, or to a device |
| `RD68021_DUMP_AT` | the last 4096 bus cycles at a clock -- also dumped automatically on a halt |
| `RD68021_FAULTS` | every bus error, and whether the same access was later retried, faulted again, or never seen again |
| `RD68021_SYSCALLS`, `RD68021_UTRACE=from:to` | SunOS system calls (D0 at every TRAP #0), and every user-mode instruction between two of them; TME's own m68k prints the same, so the two can be compared |

The log's periodic report also gives the hottest program-counter lines over the whole
address space and, for each interrupt level, how often it was raised and how the
acknowledges were answered. `sim/tme/drive.sh` types commands at the console's
prompts -- `>`, `#` or `:` unless `PROMPT` says otherwise -- each once a line has
ended and a new prompt has come back.

## The PROM patch

`tools/sun3_rom.py` changes one word, the count of the wait after the PROM writes
the diagnostic LEDs, from 65535 to 2 -- the Sun-3/160 counterpart of
`Inputs/ref/VintageBusFPGA_Common/RomPatcher/Sun3_60FastBoot`, which does the same
to the Sun-3/60's v1.9 PROM -- and puts the checksum right. It refuses a PROM
whose bytes are not the ones it expects. The EEPROM image says 4 MB rather than 8,
which halves the time the PROM spends initialising memory; neither changes a byte
of what it prints.
