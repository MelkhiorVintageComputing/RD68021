# RD68021 -- SystemVerilog MC68020
#
# Targets arrive as the milestones that need them do. `make help` lists what exists.
#
# The three always-available front-ends -- iverilog, Verilator, yosys -- are what
# `make lint` runs and what the RTL is written against day to day. Vivado, Quartus
# and Questa each have their own target and none of them is in `make check`, which
# has to work on a machine with no vendor tools installed.

SHELL := /bin/bash

TOP   ?= rd68021_top
BUILD ?= build

# Overridable build knobs, all documented where they are used.
ICACHE_ENTRIES ?= 64
COPROCESSOR    ?= 0

# Vendor tool locations. Neither is on PATH; the launchers in scripts/ set it up.
VIVADO_SETTINGS ?= /opt/Xilinx/2025.2/Vivado/settings64.sh
QUARTUS_ROOTDIR ?= /opt/Altera/quartus
QUESTA_ROOTDIR  ?= /opt/Altera/questa_fse
XPART           ?= xc7a100tcsg324-1
AFAMILY         ?= "Cyclone V"
APART           ?= 5CSEMA5F31C6

# ---------------------------------------------------------------------------
# The file list. Dependency-ordered, packages first: Vivado needs a package read
# before its users, and so does Questa.
# ---------------------------------------------------------------------------
# Packages first -- Vivado and Questa need one read before its users, and so does
# iverilog. The generated files are split the same way: a plain wildcard over
# rtl/gen/ sorts rd68021_decode_rom.sv ahead of the package it depends on.
PKGS    := rtl/rd68021_pkg.sv
GENPKG  := $(wildcard rtl/gen/*_pkg.sv)
GENSRC  := $(filter-out $(GENPKG),$(wildcard rtl/gen/*.sv))
SRCS := rtl/rd68021_sync.sv \
        rtl/rd68021_dedge_ff.sv \
        rtl/rd68021_shifter.sv \
        rtl/rd68021_divider.sv \
        rtl/rd68021_bitfield.sv \
        rtl/rd68021_biu.sv \
        rtl/rd68021_icache.sv \
        rtl/rd68021_ifu.sv \
        rtl/rd68021_seq.sv \
        rtl/rd68021_top.sv

RTL  := $(PKGS) $(GENPKG) $(GENSRC) $(SRCS)
VLT  := rtl/rd68021.vlt

IVFLAGS := -g2012 -Wall -Wno-timescale -DTB_ICACHE_ENTRIES=$(ICACHE_ENTRIES)

.PHONY: all help dirs lint lint-source lint-iverilog lint-verilator lint-yosys \
        lint-quartus lint-questa quartus synth impl paths audit ucode ucode-check sim sim-bus \
        timing timing-verbose ea cache cycles suska sun3 sunos check clean

all: lint

help:
	@echo "RD68021 -- SystemVerilog MC68020"
	@echo
	@echo "  make lint      elaborate every rtl module under iverilog, Verilator and yosys"
	@echo "  make sim       the directed testbenches"
	@echo "  make sim-bus   ... just the bus-level ones"
	@echo "  make paging    ... just the bus-fault and demand-paging ones"
	@echo "  make audit     prove no register initialises outside reset"
	@echo "  make timing    AC-specification feasibility, all four speed grades"
	@echo "  make ea        every addressing mode against Musashi"
	@echo "  make cache     the same results with no instruction cache at all"
	@echo "  make cycles    instruction clock counts against UM section 8"
	@echo "  make suska     the bus against a second core, the Suska WF68K30L"
	@echo "  make sun3      a Sun-3/160 boot PROM on the core, inside TME"
	@echo "  make sunos     SunOS 4.1.1 on that machine, to a single-user shell"
	@echo "  make ucode     regenerate rtl/gen/ from tools/ucode/"
	@echo "  make check     the gate: ucode-check, lint, audit"
	@echo
	@echo "  make synth        Vivado synthesis ($(XPART))"
	@echo "  make lint-quartus Quartus analysis and synthesis ($(AFAMILY))"
	@echo "  make lint-questa  Questa vlog + vopt"
	@echo
	@echo "Knobs: ICACHE_ENTRIES=$(ICACHE_ENTRIES) COPROCESSOR=$(COPROCESSOR)"

dirs:
	@mkdir -p $(BUILD)

# ---------------------------------------------------------------------------
# Lint -- the three that need no vendor installation
# ---------------------------------------------------------------------------
lint: lint-source lint-iverilog lint-verilator lint-yosys

# The two portability rules the three free front-ends do not enforce and the
# three vendor ones do -- declaration before use, and no package-scoped name in a
# port connection. Both are in doc/coding-standard.md and both came back once
# because nothing cheaper than a vendor run looked.
lint-source:
	@python3 tools/src_lint.py $(filter-out $(PKGS) $(GENPKG),$(RTL))
	@echo "PASS: lint"

# Both of these run the tool into a log and decide from its exit status, rather
# than piping it through a filter. `tool | grep -v ... || test $$? -eq 1` looks
# like it keeps the status and does not: with pipefail the pipeline returns the
# tool's 1, and `test 1 -eq 1` then succeeds, so a failing tool reports "ok".
# Measured, on this Makefile, twice.
#
# iverilog prints a "sorry: ..." note for every unique case and for every variable
# part-select in an always_ block, and nothing can turn them off. They are notes,
# not diagnostics, so they are filtered out of what gets shown on a failure.
NOTES := ': sorry: .*\(ignored\|all bits will be included\)\.$$'

lint-iverilog: dirs
	@iverilog $(IVFLAGS) -P$(TOP).ICACHE_ENTRIES=$(ICACHE_ENTRIES) \
	    -o $(BUILD)/$(TOP).vvp -s $(TOP) $(RTL) \
	    > $(BUILD)/iverilog.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/iverilog.log; exit 1; }
	@echo "  iverilog: ok"

lint-verilator: dirs
	@verilator --lint-only -Wall --top-module $(TOP) \
	    -GICACHE_ENTRIES=$(ICACHE_ENTRIES) $(VLT) $(RTL) \
	    > $(BUILD)/verilator.log 2>&1 \
	  || { grep -v '^- V e r i l a t i o n\|^- Verilator:' $(BUILD)/verilator.log; exit 1; }
	@echo "  verilator: ok"

# Run the full synth pass, not just read_verilog, so that anything unsynthesisable
# is caught here rather than in Vivado.
#
# yosys returns 0 on a warning, and two of its warnings are defects rather than
# noise: a register driven from two processes ("multiple conflicting drivers"),
# which is what a register written from both edge domains looks like, and an
# inferred latch. Both are gates here, not the exit code -- measured: op_addr was
# driven from both the posedge and the negedge block and `make lint` said PASS.
lint-yosys: dirs
	@set -o pipefail; yosys -p "read_verilog -sv $(RTL); \
	    chparam -set ICACHE_ENTRIES $(ICACHE_ENTRIES) $(TOP); synth -top $(TOP); \
	    write_verilog $(BUILD)/$(TOP)_yosys.v" > $(BUILD)/yosys.log 2>&1 \
	  || { tail -40 $(BUILD)/yosys.log; exit 1; }
	@if grep -q 'multiple conflicting drivers\|Warning: Identifier .* is implicitly declared\|inferring latch' $(BUILD)/yosys.log; then \
	    echo "FAIL: yosys"; \
	    grep -n 'multiple conflicting drivers\|implicitly declared\|inferring latch' $(BUILD)/yosys.log | head -20; \
	    exit 1; fi
	@echo "  yosys: ok"

# ---------------------------------------------------------------------------
# The reset rule
# ---------------------------------------------------------------------------
audit: dirs
	@python3 tools/reset_audit.py --top $(TOP) --build $(BUILD) \
	    --param ICACHE_ENTRIES=$(ICACHE_ENTRIES) $(RTL)

# ---------------------------------------------------------------------------
# Microcode -- M4
# ---------------------------------------------------------------------------
# The generated files are committed, so a build needs no Python. ucode-check is
# the first thing `make check` runs, so they cannot drift from their source.
ucode: dirs
	@python3 tools/ucode/assemble.py

ucode-check: dirs
	@python3 tools/ucode/assemble.py --check

# ---------------------------------------------------------------------------
# Directed testbenches
#
# Each one runs to completion and prints PASS or FAIL. The loop fails on a FAIL
# and ALSO on a missing PASS: a testbench that stopped early without saying so is
# not a testbench that passed.
# ---------------------------------------------------------------------------
# core_ea_tb is not here: it needs a vector file that `make ea` generates from
# Musashi first, and it runs for minutes. It has its own target.
# The instruction groups whose microcode exists. `make vectors` sweeps these;
# adding a family to tools/ucode/program.py adds its name here, and that is how
# the sweep grows with the milestone instead of being switched on at the end.
#
# Every group the generator knows how to build, since M8. `make vectors-all` is
# the same thing named for the milestone criterion, and the two stay the same
# until M10 adds instructions the generator has no group for yet.
VECGROUPS := all

TBS := $(filter-out core_ea_tb core_vec_tb core_cosim_tb core_cycles_tb,$(patsubst sim/tb/%.sv,%,$(wildcard sim/tb/*_tb.sv)))

sim: dirs
	@ok=1; for tb in $(TBS); do \
	  iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/$$tb.vvp -s $$tb \
	      $(RTL) sim/models/*.sv sim/tb/$$tb.sv > $(BUILD)/$$tb.build.log 2>&1 \
	    || { echo "FAIL: $$tb did not elaborate"; \
	         grep -v $(NOTES) $(BUILD)/$$tb.build.log; ok=0; continue; }; \
	  vvp $(BUILD)/$$tb.vvp > $(BUILD)/$$tb.log 2>&1; \
	  if grep -q '^FAIL' $(BUILD)/$$tb.log; then \
	    echo "FAIL: $$tb"; grep -E '^  FAIL|^FAIL' $(BUILD)/$$tb.log | head -30; ok=0; \
	  elif ! grep -q '^PASS' $(BUILD)/$$tb.log; then \
	    echo "FAIL: $$tb reported no PASS"; tail -20 $(BUILD)/$$tb.log; ok=0; \
	  else \
	    echo "  $$(grep -E '^PASS' $(BUILD)/$$tb.log | head -1)"; \
	  fi; \
	done; test $$ok -eq 1

sim-bus: dirs
	@$(MAKE) --no-print-directory sim TBS="$(filter bus_%,$(TBS))"

# Demand paging: every combination of UM table 5-6 faulted across a page that is
# not there, handled by a real handler, and continued. It is part of `sim`, and
# so of `check`, because it is the milestone's own criterion and a regression in
# it is the kind nothing else finds.
paging: dirs
	@$(MAKE) --no-print-directory sim TBS="core_paging_tb core_fault_tb"

# ---------------------------------------------------------------------------
# Musashi, the instruction-level oracle
#
# Inputs/ is immutable, so Musashi is built out of tree into build/musashi/, and
# tools/cosim/m68kconf.h is force-included with -include rather than put on the
# include path: Musashi includes its own with quotes, which searches its own
# directory first.
# ---------------------------------------------------------------------------
MUSASHI  := Inputs/ref/Musashi
MBUILD   := $(BUILD)/musashi
MCFLAGS  := -O2 -w -I$(MUSASHI) -include tools/cosim/m68kconf.h

$(MBUILD)/m68kmake: $(MUSASHI)/m68kmake.c
	@mkdir -p $(MBUILD)
	@cc -O2 -w -o $@ $<

$(MBUILD)/m68kops.c: $(MBUILD)/m68kmake $(MUSASHI)/m68k_in.c
	@cd $(MBUILD) && ./m68kmake . $(CURDIR)/$(MUSASHI)/m68k_in.c > /dev/null

$(MBUILD)/musashi_ea: tools/cosim/musashi_ea.c $(MBUILD)/m68kops.c \
                      tools/cosim/m68kconf.h
	@# m68kfpu.c is #included by m68kcpu.c, not compiled beside it: listing it
	@# too is "multiple definition of m68040_fpu_op1". softfloat.c is compiled
	@# separately, because m68kfpu.c only declares what it uses from it.
	@cc $(MCFLAGS) -I$(MBUILD) -I$(MUSASHI)/softfloat -o $@ $< \
	    $(MBUILD)/m68kops.c $(MUSASHI)/m68kcpu.c $(MUSASHI)/m68kdasm.c \
	    $(MUSASHI)/softfloat/softfloat.c -lm \
	    > $(BUILD)/musashi.log 2>&1 \
	  || { tail -20 $(BUILD)/musashi.log; exit 1; }

# ---------------------------------------------------------------------------
# Effective addresses, against Musashi
# ---------------------------------------------------------------------------
ea: dirs $(MBUILD)/musashi_ea
	@$(MBUILD)/musashi_ea > $(BUILD)/ea-vectors.hex
	@echo "  ea: $$(head -1 $(BUILD)/ea-vectors.hex | tr -d ' ') vectors from Musashi"
	@iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/core_ea_tb.vvp -s core_ea_tb \
	    $(RTL) sim/models/*.sv sim/tb/core_ea_tb.sv \
	    > $(BUILD)/core_ea_tb.build.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/core_ea_tb.build.log; exit 1; }
	@vvp $(BUILD)/core_ea_tb.vvp +vec=$(BUILD)/ea-vectors.hex \
	    > $(BUILD)/core_ea_tb.log 2>&1; \
	 grep -E '^  FAIL' $(BUILD)/core_ea_tb.log | head -20; \
	 grep -q '^PASS' $(BUILD)/core_ea_tb.log || { tail -3 $(BUILD)/core_ea_tb.log; exit 1; }
	@tail -2 $(BUILD)/core_ea_tb.log

$(MBUILD)/vectors_gen: tools/vectors/gen.c $(MBUILD)/m68kops.c \
                       tools/cosim/m68kconf.h
	@cc $(MCFLAGS) -I$(MBUILD) -I$(MUSASHI)/softfloat -o $@ $< \
	    $(MBUILD)/m68kops.c $(MUSASHI)/m68kcpu.c $(MUSASHI)/m68kdasm.c \
	    $(MUSASHI)/softfloat/softfloat.c -lm \
	    > $(BUILD)/vectors.log 2>&1 \
	  || { tail -20 $(BUILD)/vectors.log; exit 1; }

# ---------------------------------------------------------------------------
# The per-opcode sweep
#
#   make vectors OP=alu        one group
#   make vectors               every group the microcode has reached
#   make vectors-all           every group there is, including the unwritten
#
# OP defaults to the groups M7 has implemented so far rather than to `all`, so
# that `make vectors` is a gate that can stay green while the milestone is being
# built. `vectors-all` is the milestone's own criterion and is expected to fail
# until it closes.
# ---------------------------------------------------------------------------
OP ?= $(VECGROUPS)

vectors: dirs $(MBUILD)/vectors_gen
	@$(MBUILD)/vectors_gen $(OP) > $(BUILD)/vectors.hex 2> $(BUILD)/vectors-gen.log \
	  || { cat $(BUILD)/vectors-gen.log; exit 1; }
	@sed 's/^/  /' $(BUILD)/vectors-gen.log
	@iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/core_vec_tb.vvp -s core_vec_tb \
	    $(RTL) sim/models/*.sv sim/tb/core_vec_tb.sv \
	    > $(BUILD)/core_vec_tb.build.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/core_vec_tb.build.log; exit 1; }
	@vvp $(BUILD)/core_vec_tb.vvp +vec=$(BUILD)/vectors.hex \
	    > $(BUILD)/core_vec_tb.log 2>&1; \
	 grep -E '^  FAIL' $(BUILD)/core_vec_tb.log | head -20; \
	 grep -q '^PASS' $(BUILD)/core_vec_tb.log || { tail -3 $(BUILD)/core_vec_tb.log; exit 1; }
	@tail -2 $(BUILD)/core_vec_tb.log

vectors-all: dirs
	@$(MAKE) --no-print-directory vectors OP=all

$(MBUILD)/musashi_trace: tools/cosim/musashi_trace.c $(MBUILD)/m68kops.c \
                        tools/cosim/m68kconf.h
	@cc $(MCFLAGS) -I$(MBUILD) -I$(MUSASHI)/softfloat -o $@ $< \
	    $(MBUILD)/m68kops.c $(MUSASHI)/m68kcpu.c $(MUSASHI)/m68kdasm.c \
	    $(MUSASHI)/softfloat/softfloat.c -lm \
	    > $(BUILD)/trace.log 2>&1 \
	  || { tail -20 $(BUILD)/trace.log; exit 1; }

# ---------------------------------------------------------------------------
# Real programs, against Musashi at every instruction boundary
#
# The per-opcode sweep runs one instruction from a state nobody reached by
# executing anything. This runs a program: the instruction mix and the register
# allocation are the compiler's, and every instruction starts where the one
# before it left off.
#
# STEPS caps the trace. A program that runs for a million instructions is a fine
# thing to have and a slow gate, so `cosim` takes the first STEPS of it and
# `cosim-long` takes the lot.
# ---------------------------------------------------------------------------
CROSS   := m68k-linux-gnu-
PROGS   := arith corners
STEPS   ?= 20000
CFLAGS68 := -O2 -fno-builtin -fomit-frame-pointer -nostdlib -ffreestanding \
            -Wall -Wextra

$(BUILD)/programs/%.o: sim/programs/%.c | dirs
	@mkdir -p $(BUILD)/programs
	@$(CROSS)gcc -c $(CFLAGS68) -o $@ $<

$(BUILD)/programs/%.o: sim/programs/%.S | dirs
	@mkdir -p $(BUILD)/programs
	@$(CROSS)gcc -c -o $@ $<

.PRECIOUS: $(BUILD)/programs/%.o $(BUILD)/programs/%.elf \
           $(BUILD)/programs/%.bin $(BUILD)/programs/%.hex \
           $(BUILD)/programs/%.trc

$(BUILD)/programs/%.elf: $(BUILD)/programs/%.o $(BUILD)/programs/crt0.o \
                         sim/programs/flat.ld
	@$(CROSS)gcc -nostdlib -nostartfiles -T sim/programs/flat.ld -o $@ \
	    $(BUILD)/programs/crt0.o $< -lgcc 2> $(BUILD)/programs/$*.link.log \
	  || { cat $(BUILD)/programs/$*.link.log; exit 1; }

$(BUILD)/programs/%.bin: $(BUILD)/programs/%.elf
	@$(CROSS)objcopy -O binary $< $@

$(BUILD)/programs/%.hex: $(BUILD)/programs/%.elf
	@$(CROSS)objcopy -O verilog --verilog-data-width=1 $< $@

$(BUILD)/programs/%.trc: $(BUILD)/programs/%.bin $(MBUILD)/musashi_trace
	@$(MBUILD)/musashi_trace $< $(STEPS) > $@ 2> $(BUILD)/programs/$*.trace.log \
	  || { cat $(BUILD)/programs/$*.trace.log; exit 1; }
	@sed 's/^/  /' $(BUILD)/programs/$*.trace.log

cosim: dirs $(patsubst %,$(BUILD)/programs/%.hex,$(PROGS)) \
             $(patsubst %,$(BUILD)/programs/%.trc,$(PROGS))
	@iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/core_cosim_tb.vvp -s core_cosim_tb \
	    $(RTL) sim/models/*.sv sim/tb/core_cosim_tb.sv \
	    > $(BUILD)/core_cosim_tb.build.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/core_cosim_tb.build.log; exit 1; }
	@ok=1; for p in $(PROGS); do \
	  vvp $(BUILD)/core_cosim_tb.vvp +image=$(BUILD)/programs/$$p.hex \
	      +trace=$(BUILD)/programs/$$p.trc > $(BUILD)/cosim-$$p.log 2>&1; \
	  grep -E '^  FAIL' $(BUILD)/cosim-$$p.log | head -5; \
	  if grep -q '^PASS' $(BUILD)/cosim-$$p.log; then \
	    echo "  PASS: $$p -- $$(sed -n 's/^core_cosim_tb: \([0-9]*\) instructions.*/\1/p' $(BUILD)/cosim-$$p.log) instructions"; \
	  else \
	    echo "  FAIL: $$p"; tail -3 $(BUILD)/cosim-$$p.log; ok=0; \
	  fi; \
	done; \
	test $$ok -eq 1 && echo "PASS: cosim"

# ---------------------------------------------------------------------------
# Instruction clock counts against UM section 8
#
# One row per instruction, each a regression check against the count frozen in
# tools/cycles.py, and the table in doc/timing-divergences.md regenerated from
# the measurement. Warm is the manual's cache case; cold is the first pass, with
# the cache empty.
# ---------------------------------------------------------------------------
cycles: dirs
	@python3 tools/cycles.py gen > $(BUILD)/cycles.vec
	@iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/core_cycles_tb.vvp -s core_cycles_tb \
	    $(RTL) sim/models/*.sv sim/tb/core_cycles_tb.sv \
	    > $(BUILD)/core_cycles_tb.build.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/core_cycles_tb.build.log; exit 1; }
	@vvp $(BUILD)/core_cycles_tb.vvp +vec=$(BUILD)/cycles.vec > $(BUILD)/cycles.out 2>&1
	@grep -E '^  FAIL' $(BUILD)/cycles.out | head -20; \
	 grep -q '^PASS' $(BUILD)/cycles.out || { tail -5 $(BUILD)/cycles.out; exit 1; }
	@python3 tools/cycles.py check $(BUILD)/cycles.out --doc doc/timing-divergences.md

# ---------------------------------------------------------------------------
# The instruction cache is architecturally invisible
#
# UM 4.1 caches instruction prefetches and nothing else, so a core built with no
# cache at all must give the same answers. This runs the directed testbenches,
# the sweep and the effective-address vectors on a core with ICACHE_ENTRIES=0,
# and then every program on both builds, holding the two to identical data
# cycles and to no more instruction fetches with the cache than without.
# ---------------------------------------------------------------------------
NOCACHE := $(BUILD)/nocache

cache: dirs $(patsubst %,$(BUILD)/programs/%.hex,$(PROGS)) \
            $(patsubst %,$(BUILD)/programs/%.trc,$(PROGS))
	@echo "  -- ICACHE_ENTRIES=0: the directed testbenches"
	@$(MAKE) --no-print-directory sim ICACHE_ENTRIES=0 BUILD=$(NOCACHE)
	@echo "  -- ICACHE_ENTRIES=0: the sweep and the effective addresses"
	@$(MAKE) --no-print-directory vectors ea ICACHE_ENTRIES=0 BUILD=$(NOCACHE) \
	    MBUILD=$(MBUILD)
	@echo "  -- the programs, both ways"
	@ok=1; for e in 0 64; do \
	  iverilog -g2012 -Wall -Wno-timescale -DTB_ICACHE_ENTRIES=$$e -I sim/tb \
	      -o $(NOCACHE)/cosim$$e.vvp -s core_cosim_tb \
	      $(RTL) sim/models/*.sv sim/tb/core_cosim_tb.sv \
	      > $(NOCACHE)/cosim$$e.build.log 2>&1 \
	    || { grep -v $(NOTES) $(NOCACHE)/cosim$$e.build.log; exit 1; }; \
	done; \
	for p in $(PROGS); do \
	  for e in 0 64; do \
	    vvp $(NOCACHE)/cosim$$e.vvp +image=$(BUILD)/programs/$$p.hex \
	        +trace=$(BUILD)/programs/$$p.trc +buslog=$(NOCACHE)/$$p.$$e.bus \
	        > $(NOCACHE)/cosim-$$p.$$e.log 2>&1; \
	    grep -q '^PASS' $(NOCACHE)/cosim-$$p.$$e.log \
	      || { echo "  FAIL: $$p with $$e entries"; tail -3 $(NOCACHE)/cosim-$$p.$$e.log; ok=0; }; \
	  done; \
	  r=$$(python3 tools/cache_diff.py $(NOCACHE)/$$p.0.bus $(NOCACHE)/$$p.64.bus) \
	    && echo "  PASS: $$p -- $$r" || { echo "  $$r"; ok=0; }; \
	done; \
	test $$ok -eq 1 && echo "PASS: cache"

# ---------------------------------------------------------------------------
# A second core: the Suska WF68K30L under ghdl
#
# The same probe (sim/suska/bus_probe.S) on both cores against the same three
# ports, and the data cycles compared one bus cycle at a time: how every operand
# size at every offset splits across a 32-, 16- and 8-bit port, what SIZ says,
# what goes on all four write lanes, and where RMC is held. Suska is RUN here and
# never read -- CLAUDE.md. Its sources are compiled out of tree, in build/suska.
# ---------------------------------------------------------------------------
SUSKA    := Inputs/ref/Suska_Configware/68K30L
SUSKADIR := $(BUILD)/suska
SUSKAVHD := wf68k30L_pkg wf68k30L_address_registers wf68k30L_alu \
            wf68k30L_bus_interface wf68k30L_control wf68k30L_data_registers \
            wf68k30L_exception_handler wf68k30L_opcode_decoder wf68k30L_top
GHDLFLAGS := --std=08 -fsynopsys -Wno-hide

suska: dirs
	@mkdir -p $(SUSKADIR)
	@$(CROSS)gcc -c -o $(SUSKADIR)/bus_probe.o sim/suska/bus_probe.S
	@$(CROSS)ld -T sim/suska/probe.ld -o $(SUSKADIR)/bus_probe.elf $(SUSKADIR)/bus_probe.o
	@$(CROSS)objcopy -O binary $(SUSKADIR)/bus_probe.elf $(SUSKADIR)/bus_probe.bin
	@python3 -c "import sys; b=open(sys.argv[1],'rb').read(); \
	    open(sys.argv[2],'w').write(''.join('%02x\n' % x for x in b))" \
	    $(SUSKADIR)/bus_probe.bin $(SUSKADIR)/bus_probe.hex
	@cd $(SUSKADIR) && for f in $(SUSKAVHD); do \
	  ghdl -a $(GHDLFLAGS) $(CURDIR)/$(SUSKA)/$$f.vhd > $$f.log 2>&1 \
	    || { echo "FAIL: ghdl could not analyse $$f"; tail -5 $$f.log; exit 1; }; \
	done
	@cd $(SUSKADIR) && ghdl -a $(GHDLFLAGS) $(CURDIR)/sim/suska/wf68k30l_tb.vhd \
	  && ghdl -e $(GHDLFLAGS) wf68k30l_tb && ./wf68k30l_tb > suska.bus 2> suska.err
	@iverilog $(IVFLAGS) -I sim/tb -o $(SUSKADIR)/rd68021_bus_tb.vvp -s rd68021_bus_tb \
	    $(RTL) sim/models/*.sv sim/suska/rd68021_bus_tb.sv \
	    > $(SUSKADIR)/rd68021_bus_tb.build.log 2>&1 \
	  || { grep -v $(NOTES) $(SUSKADIR)/rd68021_bus_tb.build.log; exit 1; }
	@vvp $(SUSKADIR)/rd68021_bus_tb.vvp +image=$(SUSKADIR)/bus_probe.hex > $(SUSKADIR)/rd68021.bus
	@python3 tools/suska_diff.py $(SUSKADIR)/suska.bus $(SUSKADIR)/rd68021.bus

# ---------------------------------------------------------------------------
# A whole machine: the Sun-3/160 boot PROM, on the RTL core, inside TME
#
# TME (Inputs/ref/Run-Sun3-SunOS-4.1.1/tme-0.8_up) is copied into build/tme and
# built with one more CPU element, tme/ic/rd68021, whose CPU is the Verilator
# model of the core (sim/tme/). The Sun-3's MMU, control space, interrupt logic,
# memory and devices are TME's; the bus cycles are the core's, answered through
# TME's own MC68020 byte-lane router. The same machine is then booted twice --
# on TME's m68020 and on the core -- and the console output must be identical
# and end at the monitor's prompt.
#
# The PROM is a copy, patched by tools/sun3_rom.py to skip a display wait, and
# the EEPROM says 4 MB so that memory initialisation takes half as long; neither
# changes what the PROM prints. The run stops once the monitor has sat in its
# character input (0x0FEF0F56) a thousand samples running.
# ---------------------------------------------------------------------------
SUN3DIR  := $(BUILD)/sun3
SUN3SRC  := Inputs/ref/Run-Sun3-SunOS-4.1.1
TMEINST  := $(BUILD)/tme/inst
TMEENV   := LTDL_LIBRARY_PATH=$(CURDIR)/$(TMEINST)/lib

sun3: dirs
	@sim/tme/build.sh $(CURDIR) $(RTL)
	@mkdir -p $(SUN3DIR)
	@python3 tools/sun3_rom.py $(SUN3SRC)/sun3-carrera-rev-3.0.bin $(SUN3DIR)/prom.bin
	@sed 's/^console-device .*/console-device ttya/; s/^installed-#megs .*/installed-#megs 4/' \
	    $(SUN3SRC)/sun3-carrera-eeprom.txt > $(SUN3DIR)/eeprom.txt
	@$(TMEENV) $(TMEINST)/bin/tme-sun-eeprom < $(SUN3DIR)/eeprom.txt > $(SUN3DIR)/eeprom.bin 2>/dev/null
	@# tme-sun-idprom makes an IDPROM only when its input is a terminal.
	@cd $(SUN3DIR) && script -qc "$(CURDIR)/$(TMEINST)/bin/tme-sun-idprom 3/150 \
	    8:0:20:11:22:33 > sun3-idprom.bin" /dev/null
	@for cpu in m68020 rd68021; do \
	  d=$(SUN3DIR)/$$cpu; mkdir -p $$d; \
	  cp $(SUN3DIR)/prom.bin $(SUN3DIR)/sun3-idprom.bin $$d/; \
	  cp $(SUN3DIR)/eeprom.bin $$d/sun3-eeprom.bin; \
	  arg=tme/ic/$$cpu; [ $$cpu = rd68021 ] && arg="tme/ic/rd68021 log rd68021.log"; \
	  sed "s|@CPU@|$$arg|; s|@ROM@|prom.bin|" sim/tme/SUN3.in > $$d/SUN3; \
	  : > $$d/console.in; : > $$d/console.out; \
	done
	@# TME's own CPU runs until it is stopped; twenty seconds is several times what it needs.
	@cd $(SUN3DIR)/m68020 && ($(TMEENV) timeout 20 $(CURDIR)/$(TMEINST)/bin/tmesh SUN3 \
	    < /dev/null > tmesh.log 2>&1 || true)
	@cd $(SUN3DIR)/rd68021 && $(TMEENV) RD68021_STOP_PC=0x0fef0f56 timeout 1800 \
	    $(CURDIR)/$(TMEINST)/bin/tmesh SUN3 < /dev/null > tmesh.log 2>&1 \
	  || { echo "FAIL: sun3 -- the core's machine did not stop by itself"; \
	       tail -5 $(SUN3DIR)/rd68021/tmesh.log; exit 1; }
	@grep '^rd68021: [0-9]' $(SUN3DIR)/rd68021/rd68021.log | tail -1 | sed 's/^/  /'
	@if cmp -s $(SUN3DIR)/m68020/console.out $(SUN3DIR)/rd68021/console.out \
	    && tail -c 1 $(SUN3DIR)/rd68021/console.out | grep -q '>'; then \
	  echo "  sun3: $$(wc -c < $(SUN3DIR)/rd68021/console.out) bytes of console output identical to TME's m68020, ending at the monitor prompt"; \
	  echo "PASS: sun3"; \
	else \
	  echo "FAIL: sun3 -- the console output differs"; \
	  diff <(tr -d '\r\000' < $(SUN3DIR)/m68020/console.out) \
	       <(tr -d '\r\000' < $(SUN3DIR)/rd68021/console.out) | head -20; exit 1; \
	fi

# ---------------------------------------------------------------------------
# SunOS 4.1.1 on the same machine -- doc/sun3.md
#
# `make sun3`'s machine with a SCSI tape holding the installation tape's first
# five files, and the EEPROM's boot device pointed at it: st(0,32,0), SCSI target
# 4 as the PROM counts. The PROM boots the install kernel, MUNIX, which asks what
# to do; sim/tme/drive.sh answers 2, for a single-user shell, and types two
# commands at it. The console must be byte for byte what TME's m68020 prints,
# ending at the shell's prompt. The core takes about three minutes.
# ---------------------------------------------------------------------------
SUNOSDIR := $(BUILD)/sunos-boot
SUNOSCMD := 2 "ls /" "echo hello from the shell"

sunos: sun3
	@sed 's/^boot-device .*/boot-device st(0,32,0)/' $(SUN3DIR)/eeprom.txt > $(SUN3DIR)/eeprom-st.txt
	@$(TMEENV) $(TMEINST)/bin/tme-sun-eeprom < $(SUN3DIR)/eeprom-st.txt > $(SUN3DIR)/eeprom-st.bin 2>/dev/null
	@for cpu in m68020 rd68021; do \
	  d=$(SUNOSDIR)/$$cpu; rm -rf $$d; mkdir -p $$d; \
	  cp $(SUN3DIR)/prom.bin $(SUN3DIR)/sun3-idprom.bin $$d/; \
	  cp $(SUN3DIR)/eeprom-st.bin $$d/sun3-eeprom.bin; \
	  truncate -s 300000000 $$d/disk.img; \
	  arg=tme/ic/$$cpu; [ $$cpu = rd68021 ] && arg="tme/ic/rd68021 log rd68021.log"; \
	  sed "s|@CPU@|$$arg|; s|@ROM@|prom.bin|; s|@TAPE@|$(CURDIR)/$(SUN3SRC)/sunos411|g" \
	      sim/tme/SUNOS.in > $$d/SUNOS; \
	  (cd $$d && PROMPT='1 or 2: *|# *' T=$(CURDIR)/$(TMEINST) \
	      $(CURDIR)/sim/tme/drive.sh SUNOS 3000 $(SUNOSCMD) > /dev/null 2>&1); \
	done
	@if cmp -s $(SUNOSDIR)/m68020/console.out $(SUNOSDIR)/rd68021/console.out \
	    && tr -d '\r\000' < $(SUNOSDIR)/rd68021/console.out | tail -c 2 | grep -q '^# $$'; then \
	  tr -d '\r\000' < $(SUNOSDIR)/rd68021/console.out | tail -6 | sed 's/^/    /'; echo; \
	  echo "  sunos: $$(wc -c < $(SUNOSDIR)/rd68021/console.out) bytes of console output identical to TME's m68020, ending at SunOS's shell prompt"; \
	  echo "PASS: sunos"; \
	else \
	  echo "FAIL: sunos -- the console output differs"; \
	  diff <(tr -d '\r\000' < $(SUNOSDIR)/m68020/console.out) \
	       <(tr -d '\r\000' < $(SUNOSDIR)/rd68021/console.out) | head -20; exit 1; \
	fi

cosim-long: dirs
	@$(MAKE) --no-print-directory cosim STEPS=4000000

# ---------------------------------------------------------------------------
# AC timing
#
# One run per speed grade. The analysis measures separations in clock edges, so a
# recording made at one frequency is evidence about that frequency and nothing
# else: judging a 60 ns recording against the 33.33 MHz limits would credit the
# design with half-clocks it does not have there.
#
# Specification 1 gives each grade's minimum cycle time, and those are the four
# periods below.
# ---------------------------------------------------------------------------
TIMGRADES := 60:16_67 50:20 40:25 30:33_33
PADSKEW   ?= 0

timing: dirs
	@iverilog $(IVFLAGS) -I sim/tb -o $(BUILD)/rd68021_timing_tb.vvp \
	    -s rd68021_timing_tb $(RTL) sim/models/*.sv sim/tb/rd68021_timing_tb.sv \
	    > $(BUILD)/timing.build.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/timing.build.log; exit 1; }
	@ok=1; for g in $(TIMGRADES); do \
	  p=$${g%%:*}; f=$${g##*:}; \
	  vvp $(BUILD)/rd68021_timing_tb.vvp +period=$$p \
	      +log=$(BUILD)/timing-$$f.log > $(BUILD)/timing-run-$$f.log 2>&1; \
	  grep -q '^PASS' $(BUILD)/timing-run-$$f.log \
	    || { echo "FAIL: the timing testbench did not complete at $$p ns"; ok=0; }; \
	  python3 tools/timing/analyse.py --freq $$f --pad-skew $(PADSKEW) \
	      $(BUILD)/timing-$$f.log || ok=0; \
	done; \
	test $$ok -eq 1 && echo "PASS: timing"

timing-verbose: dirs
	@$(MAKE) --no-print-directory timing 2>&1 | head -5
	@python3 tools/timing/analyse.py --freq 16_67 --verbose $(BUILD)/timing-16_67.log

# ---------------------------------------------------------------------------
# The gate
# ---------------------------------------------------------------------------
check: ucode-check lint audit sim timing
	@echo "PASS: check"

# ---------------------------------------------------------------------------
# Vendor front-ends. Each has its own target and none is in `check`.
# ---------------------------------------------------------------------------
synth: dirs
	@printf '%s\n' $(RTL) > $(BUILD)/rtl.f
	@scripts/vivado.sh -mode batch -nojournal -nolog -source scripts/synth.tcl \
	    -tclargs $(BUILD) $(TOP) $(XPART) $(ICACHE_ENTRIES) $(COPROCESSOR)

# Place and route, for the frequency that means something. Out of context, with
# hierarchy kept. Reports land in $(BUILD)/impl_*.rpt and the checkpoint beside
# them, which `make paths` reads.
impl: dirs
	@printf '%s\n' $(addprefix $(CURDIR)/,$(RTL)) > $(BUILD)/rtl.f
	@cd $(BUILD) && $(CURDIR)/scripts/vivado.sh -mode batch -nojournal -nolog \
	    -source $(CURDIR)/scripts/impl.tcl \
	    -tclargs $(XPART) $(TOP) $(CURDIR) $(ICACHE_ENTRIES) $(COPROCESSOR) \
	    > impl.log 2>&1; rc=$$?; \
	  grep -E '^(RD68021|ERROR|CRITICAL WARNING)' impl.log; exit $$rc

# What limits the frequency, with the routes the microcode cannot take excluded
# -- scripts/paths.tcl says which and why. Runs on the checkpoint `make impl`
# left behind. doc/critical-path.md is written from it.
paths: dirs
	@cd $(BUILD) && $(CURDIR)/scripts/vivado.sh -mode batch -nojournal -nolog \
	    -source $(CURDIR)/scripts/paths.tcl -tclargs $(CURDIR) > paths.log 2>&1 || \
	    { grep -E '^(RD68021-PATHS|ERROR)' paths.log; exit 1; }
	@grep -E '^RD68021-PATHS' $(BUILD)/paths.log
	@python3 tools/paths_report.py $(BUILD)/paths_activatable.rpt

# quartus_map returns 0 on the one thing that matters most here, so the grep is the
# gate and not the exit code: a package-scoped constant inside an instantiation's
# port expression becomes an implicit one-bit net and a Warning (10236), which is a
# netlist that quietly stops matching the source.
# The pipe into tee would throw the exit status away along with everything else, so
# pipefail is not optional here: without it a Tcl error inside quartus_sh reports
# "quartus: ok" and the gate cannot fail. Measured, on this Makefile.
lint-quartus: dirs
	@printf '%s\n' $(RTL) > $(BUILD)/rtl.f
	@set -o pipefail; scripts/altera.sh quartus_sh -t scripts/quartus.tcl map \
	    $(BUILD) $(TOP) $(AFAMILY) $(APART) $(ICACHE_ENTRIES) $(COPROCESSOR) \
	    | tee $(BUILD)/quartus_map.log
	@if grep -q 'Implicit Net warning\|Warning (10236)' $(BUILD)/quartus_map.log; then \
	    echo "FAIL: quartus found an implicit net -- the netlist does not match the source"; \
	    grep 'Warning (10236)' $(BUILD)/quartus_map.log; exit 1; fi
	@echo "  quartus: ok"

# Quartus place and route and timing, for a second toolchain's number. The fit
# is its own build directory so that a fit and a lint-quartus do not share a
# project. Quartus's Fmax scales both clock edges together, which is what this
# design's edge-to-edge paths need, so it is quoted directly.
QBUILD := $(BUILD)/quartus

quartus: dirs
	@mkdir -p $(QBUILD)
	@printf '%s\n' $(RTL) > $(QBUILD)/rtl.f
	@set -o pipefail; scripts/altera.sh quartus_sh -t scripts/quartus.tcl fit \
	    $(QBUILD) $(TOP) $(AFAMILY) $(APART) $(ICACHE_ENTRIES) $(COPROCESSOR) \
	    > $(QBUILD)/fit.log 2>&1 || { grep -E '^QUARTUS|Error' $(QBUILD)/fit.log | head; exit 1; }
	@if grep -q 'Warning (10236)' $(QBUILD)/fit.log; then \
	    echo "FAIL: quartus found an implicit net"; exit 1; fi
	@grep -E '^QUARTUS' $(QBUILD)/fit.log
	@grep -A12 'Slow 1100mV 85C Model Fmax Summary' $(QBUILD)/quartus_out/$(TOP).sta.rpt \
	    | grep -E 'MHz' | head -3
	@grep -E 'Logic utilization|Total registers|Total block memory bits|Total DSP|Total RAM Blocks' \
	    $(QBUILD)/quartus_out/$(TOP).fit.summary

lint-questa: dirs
	@scripts/questa.sh $(BUILD) $(TOP) $(RTL)
	@echo "  questa: ok"

print-rtl:
	@echo $(RTL)

clean:
	rm -rf $(BUILD)
