# The clock period the design can actually run at, from the paths Vivado reports.
#
# Sourced by impl.tcl and paths.tcl. The bus unit works on both edges, so about
# half this design's paths have HALF a period to settle in -- falling edge to
# rising or rising to falling -- and the rest a whole one. Dividing the worst
# slack into the period, which is what a single-edge design would do, reads a
# half-period path's slack as if it had a whole period and gets the frequency
# wrong (doc/coding-standard.md, "Do not convert a slack into a frequency by
# dividing"). So each path is scaled by its own requirement: a path that needs d
# nanoseconds of a requirement r that is a fraction r/T of the period needs a
# period of d * T / r.

proc rd_fmax {{n 4000}} {
    set period [get_property PERIOD [get_clocks clk]]
    set worst 0.0
    set wp {}
    foreach p [get_timing_paths -delay_type max -max_paths $n -nworst 1] {
        set req [get_property REQUIREMENT $p]
        set sl  [get_property SLACK $p]
        if {$req <= 0} { continue }
        set need [expr {($req - $sl) * $period / $req}]
        if {$need > $worst} { set worst $need; set wp $p }
    }
    return [list $worst $wp]
}

proc rd_report_fmax {tag} {
    lassign [rd_fmax] need p
    puts [format "%s: needs a period of %.2f ns -- %.2f MHz" $tag $need [expr {1000.0 / $need}]]
    puts "$tag: limited by [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p]\
          ([get_property LOGIC_LEVELS $p] levels, requirement [get_property REQUIREMENT $p] ns)"
    return $need
}
