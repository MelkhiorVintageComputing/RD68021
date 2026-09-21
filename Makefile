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
ICACHE_ENTRIES ?= 0
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
        rtl/rd68021_biu.sv \
        rtl/rd68021_ifu.sv \
        rtl/rd68021_seq.sv \
        rtl/rd68021_top.sv

RTL  := $(PKGS) $(GENPKG) $(GENSRC) $(SRCS)
VLT  := rtl/rd68021.vlt

IVFLAGS := -g2012 -Wall -Wno-timescale

.PHONY: all help dirs lint lint-iverilog lint-verilator lint-yosys \
        lint-quartus lint-questa synth audit ucode ucode-check sim sim-bus \
        timing timing-verbose ea check clean

all: lint

help:
	@echo "RD68021 -- SystemVerilog MC68020"
	@echo
	@echo "  make lint      elaborate every rtl module under iverilog, Verilator and yosys"
	@echo "  make sim       the directed testbenches"
	@echo "  make sim-bus   ... just the bus-level ones"
	@echo "  make audit     prove no register initialises outside reset"
	@echo "  make timing    AC-specification feasibility, all four speed grades"
	@echo "  make ea        every addressing mode against Musashi"
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
lint: lint-iverilog lint-verilator lint-yosys
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
	@iverilog $(IVFLAGS) -o $(BUILD)/$(TOP).vvp -s $(TOP) $(RTL) \
	    > $(BUILD)/iverilog.log 2>&1 \
	  || { grep -v $(NOTES) $(BUILD)/iverilog.log; exit 1; }
	@echo "  iverilog: ok"

lint-verilator: dirs
	@verilator --lint-only -Wall --top-module $(TOP) $(VLT) $(RTL) \
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
	@set -o pipefail; yosys -p "read_verilog -sv $(RTL); synth -top $(TOP); \
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
	@python3 tools/reset_audit.py --top $(TOP) --build $(BUILD) $(RTL)

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

TBS := $(filter-out core_ea_tb core_vec_tb core_cosim_tb,$(patsubst sim/tb/%.sv,%,$(wildcard sim/tb/*_tb.sv)))

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

lint-questa: dirs
	@scripts/questa.sh $(BUILD) $(TOP) $(RTL)
	@echo "  questa: ok"

clean:
	rm -rf $(BUILD)
