# What limits this design's frequency, and proof that nothing unreachable does.
#
#   vivado -mode batch -source scripts/paths.tcl -tclargs <repo-root>
#
# Until the routes below were taken out of the RTL, the worst path static timing
# found was one the microcode could not take -- an operand into the bit-field
# unit or the shifter whose result then decided the next micro-address -- and
# this script cut those routes out of a report to show what was left. Now they
# do not exist: the conditions on a microword's own result and the status
# register a decoding microword writes are computed from the registers it reads
# (tools/ucode/assemble.py's check_live_shape holds each to its one shape), and
# the shifter has an operand multiplexer of its own (check_shift_src). So static
# timing is the real answer, and what this script does is check that it stays
# that way: each route must have no path at all, and the build fails if one
# comes back. Then it groups the worst paths into families. doc/critical-path.md.
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
rd_report_fmax "RD68021-PATHS: static"

# Each route is a PAIR of -through points on module pins, which survive
# -flatten_hierarchy none where nets get merged and renamed. Everything upc_nxt
# feeds: the microcode store's address, the micro-PC itself, and the latch that
# notes an interrupt being entered (upc_nxt == ENTRY_IRQ).
set to_upc [concat \
    [get_pins -quiet u_seq/u_urom/addr[*]] \
    [get_pins -quiet -filter {REF_PIN_NAME == D || REF_PIN_NAME == CE} \
         -of_objects [get_cells -quiet {u_seq/upc_reg[*] u_seq/irq_taking_q_reg[*]}]]]
set bf_out [filter [get_pins -quiet u_seq/u_bf/*] {DIRECTION == OUT}]
set routes [list \
    [list shifter-to-upc \
          [filter [get_pins -quiet u_seq/u_shifter/*] {DIRECTION == OUT}] $to_upc] \
    [list bitfield-to-upc $bf_out $to_upc] \
    [list bitfield-to-shifter $bf_out \
          [filter [get_pins -quiet u_seq/u_shifter/*] {DIRECTION == IN}]] \
]

set bad 0
foreach r $routes {
    lassign $r name frm to
    if {[llength $frm] == 0 || [llength $to] == 0} {
        puts "RD68021-PATHS: route $name names nothing\
              ([llength $frm] and [llength $to] pins) -- ABORT"
        exit 1
    }
    set p [get_timing_paths -quiet -delay_type max -max_paths 1 \
               -through $frm -through $to]
    if {[llength $p] == 0} {
        puts "RD68021-PATHS: $name: no path, as intended"
    } else {
        puts "RD68021-PATHS: FAIL: $name has a path again, slack [get_property SLACK $p] ns"
        set bad 1
    }
}

report_timing -delay_type max -max_paths 3000 -unique_pins -nworst 1 \
    -file paths_activatable.rpt
if {$bad} { exit 1 }
exit 0
