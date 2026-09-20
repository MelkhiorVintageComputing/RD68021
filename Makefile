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
PKGS := rtl/rd68021_pkg.sv
GEN  := $(wildcard rtl/gen/*.sv)
SRCS := rtl/rd68021_sync.sv \
        rtl/rd68021_dedge_ff.sv \
        rtl/rd68021_biu.sv \
        rtl/rd68021_ifu.sv \
        rtl/rd68021_seq.sv \
        rtl/rd68021_top.sv

RTL  := $(PKGS) $(GEN) $(SRCS)
VLT  := rtl/rd68021.vlt

IVFLAGS := -g2012 -Wall -Wno-timescale

.PHONY: all help dirs lint lint-iverilog lint-verilator lint-yosys \
        lint-quartus lint-questa synth audit ucode ucode-check check clean

all: lint

help:
	@echo "RD68021 -- SystemVerilog MC68020"
	@echo
	@echo "  make lint      elaborate every rtl module under iverilog, Verilator and yosys"
	@echo "  make audit     prove no register initialises outside reset"
	@echo "  make ucode     regenerate the microcode ROMs from tools/ucode/"
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

# iverilog prints a "sorry: ... unique ... ignored" note for every unique case and
# nothing can turn it off. Filter it, but keep the exit status: a pipe into grep
# throws the status away along with the notes, and then a module that stopped
# elaborating leaves the last output that did, and the next step runs that instead.
define iverilog_quiet
	set -o pipefail; iverilog $(IVFLAGS) $(1) 2>&1 | grep -v ': sorry: .*ignored\.$$' || test $$? -eq 1
endef

lint-iverilog: dirs
	@$(call iverilog_quiet,-o $(BUILD)/$(TOP).vvp -s $(TOP) $(RTL))
	@echo "  iverilog: ok"

# The success banner goes to stdout and there is no flag for it, so filter it --
# with pipefail, because the exit status is the whole point.
lint-verilator:
	@set -o pipefail; verilator --lint-only -Wall --top-module $(TOP) $(VLT) $(RTL) \
	    2>&1 | grep -v '^- V e r i l a t i o n\|^- Verilator:' || test $$? -eq 1
	@echo "  verilator: ok"

# Run the full synth pass, not just read_verilog, so that anything unsynthesisable
# is caught here rather than in Vivado.
lint-yosys: dirs
	@yosys -q -p "read_verilog -sv $(RTL); synth -top $(TOP); write_verilog $(BUILD)/$(TOP)_yosys.v"
	@echo "  yosys: ok"

# ---------------------------------------------------------------------------
# The reset rule
# ---------------------------------------------------------------------------
audit: dirs
	@python3 tools/reset_audit.py --top $(TOP) --build $(BUILD) $(RTL)

# ---------------------------------------------------------------------------
# Microcode -- M4
# ---------------------------------------------------------------------------
ucode: dirs
	@if [ -f tools/ucode/assemble.py ]; then python3 tools/ucode/assemble.py; \
	 else echo "  ucode: nothing to build yet (M4)"; fi

ucode-check: dirs
	@if [ -f tools/ucode/assemble.py ]; then python3 tools/ucode/assemble.py --check; \
	 else echo "  ucode-check: nothing to check yet (M4)"; fi

# ---------------------------------------------------------------------------
# The gate
# ---------------------------------------------------------------------------
check: ucode-check lint audit
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
