# What actually limits this design's frequency?
#
#   vivado -mode batch -source scripts/paths.tcl -tclargs <repo-root>
#
# `make impl` reports the worst path static timing analysis can find. For this
# design that is a path the microcode cannot take: an operand read into the
# bit-field unit or the shifter, whose result then decides the next
# micro-address. The result bus reaches the micro-address by two routes only --
# a condition that reads the microword's own result, and a status-register write
# that the interrupt test sees the same clock -- and tools/ucode/assemble.py's
# check_live_cond refuses to build a microword on either route that takes its
# result from the shifter, the bit-field unit, the multiplier or the divider.
#
# Static timing analysis cannot know that, so the reported number answers a
# question nobody asked. This asks the other one: with those routes excluded,
# what is left? The exclusions are reporting aids and are deliberately not in
# scripts/rd68021.xdc: they depend on which microwords exist, which a constraint
# file cannot say, and a build that trusted them would stop timing the routes
# the day the microcode changed. Here they only shape a report, and the check
# that justifies them is in `make ucode-check`, which is in `make check`.
#
# Runs on the checkpoint `make impl` leaves behind, so it costs minutes, not an
# hour.

set root [lindex $argv 0]
set dcp  $root/build/rd68021_top_impl.dcp
if {![file exists $dcp]} {
    puts "RD68021-PATHS: no $dcp -- run `make impl` first"
    exit 1
}
open_checkpoint $dcp
source $root/scripts/fmax.tcl

set base [rd_report_fmax "RD68021-PATHS: baseline"]
report_timing -delay_type max -max_paths 400 -unique_pins -nworst 1 \
    -file paths_baseline.rpt

# Each exclusion is a PAIR of -through points, so it cuts only the
# concatenation: the shifter is timed into the register file, and the
# micro-address is timed from the ALU; it is the one reaching the other that is
# cut. Both ends are module pins, which survive -flatten_hierarchy none where
# nets get merged and renamed.
# Everything upc_nxt feeds: the microcode store's address, the micro-PC itself,
# and the latch that notes an interrupt being entered (upc_nxt == ENTRY_IRQ).
set to_upc [concat \
    [get_pins -quiet u_seq/u_urom/addr[*]] \
    [get_pins -quiet -filter {REF_PIN_NAME == D || REF_PIN_NAME == CE} \
         -of_objects [get_cells -quiet {u_seq/upc_reg[*] u_seq/irq_taking_q_reg[*]}]]]
set exclusions [list \
    [list shifter-to-upc \
          [filter [get_pins -quiet u_seq/u_shifter/*] {DIRECTION == OUT}]] \
    [list bitfield-to-upc \
          [filter [get_pins -quiet u_seq/u_bf/*] {DIRECTION == OUT}]] \
]

# ... and the bit-field unit into the shifter: tools/ucode/assemble.py's
# check_shift_src holds the shifter to a data register or read data.
lappend exclusions [list bitfield-to-shifter \
    [filter [get_pins -quiet u_seq/u_bf/*] {DIRECTION == OUT}] \
    [filter [get_pins -quiet u_seq/u_shifter/*] {DIRECTION == IN}]]

foreach e $exclusions {
    lassign $e name frm to
    if {$to eq ""} { set to $to_upc }
    if {[llength $frm] == 0 || [llength $to] == 0} {
        puts "RD68021-PATHS: exclusion $name names nothing\
              ([llength $frm] and [llength $to] pins) -- ABORT"
        exit 1
    }
    set before [get_timing_paths -quiet -delay_type max -max_paths 1 \
                    -through $frm -through $to]
    if {[llength $before] == 0} {
        puts "RD68021-PATHS: $name is not in the design at all"
        continue
    }
    puts "RD68021-PATHS: $name cuts a path of slack [get_property SLACK $before] ns"
    set_false_path -through $frm -through $to
}

set real [rd_report_fmax "RD68021-PATHS: activatable"]
puts [format "RD68021-PATHS: the exclusions are worth %.2f ns of period" [expr {$base - $real}]]
report_timing -delay_type max -max_paths 3000 -unique_pins -nworst 1 \
    -file paths_activatable.rpt
exit 0
