# Only useful for TclKit
# (this file is include in tclvfs so this entire package can be
# use in tclkit if desired).
#
# Scripted document support
#
# 2000/03/12 jcw v0.1	initial version
# 2000/09/30 jcw v0.2	added extendPath
#
# Copyright (C) 2000 Jean-Claude Wippler <jcw@equi4.com>

package require vfs
package provide scripdoc 0.3

namespace eval scripdoc {
    variable self	;# the scripted document file
    variable script	;# the script which is started up

    namespace export init extendPath
}

proc scripdoc::init {version driver args} {
    variable self
    variable script
    global errorInfo tk_library

    set self [info script]
    set root [file tail [file rootname $self]]

    if {$root == ""} {
	error "scripdoc::init can only be called from a script file"
    }

    if {[catch {
	if {$version != 1.0} {
	    error "Unsupported scripdoc format (need $version, have 1.0)"
	}

	array set opts {m -nocommit}
	array set opts $args

	package require ${driver}vfs
	::vfs::${driver}::Mount $self $self $opts(m)

	extendPath $self

	foreach name [list $root main help] {
	    set script [file join $self bin $name.tcl]
	    if {[file exists $script]} break
	}

	if {![file exists $script]} {
	    error "don't know how to run $root for $self"
	}

	uplevel [list source $script]
    } msg]} {
	if {[info exists tk_library]} {
	    wm withdraw .
	    tk_messageBox -icon error -message $msg -title "Fatal error"
	} elseif {"[info commands eventlog][info procs eventlog]" != ""} {
	    eventlog error $errorInfo
	} else {
	    puts stderr $errorInfo
	}
	exit
    }
}

# Extend auto_path with a set of directories, if they exist.
#
# The following paths may be added (but in the opposite order):
#	$base/lib
#	$base/lib/arch/$tcl_platform(machine)
#	$base/lib/arch/$tcl_platform(platform)
#	$base/lib/arch/$tcl_platform(os)
#	$base/lib/arch/$tcl_platform(os)/$tcl_platform(osVersion)
#
# The last two entries are actually expanded even further, splitting
# $tcl_platform(os) on spaces and $tcl_platform(osVersion) on ".".
#
# So on NT, "Windows" and "Windows/NT" would also be considered, and on
# Linux 2.2.14, all of the following: Linux/2, Linux/2/2, Linux/2/2/14
#
# Only paths for which the dir exist are added (once) to auto_path.

proc scripdoc::extendPath {base {verbose 0}} {
    global auto_path
    upvar #0 tcl_platform pf

    set path [file join $base lib]
    if {[file isdirectory $path]} {
	set pos [lsearch $auto_path $path]
	if {$pos < 0} {
	    set pos [llength $auto_path]
	    lappend auto_path $path
	}
	
	if {$verbose} {
	    set tmp [join [concat {{}} $auto_path] "\n      "]
	    tclLog "scripDoc::extendPath $base -> auto_path is: $tmp"
	}

	foreach suffix [list $pf(machine) \
			     $pf(platform) \
			     [list $pf(os) $pf(osVersion)] \
			     [concat [split $pf(os) " "] \
			     	     [split $pf(osVersion) .]]] {

	    set tmp [file join $path arch]
	    foreach x $suffix {
	    	set tmp [file join $tmp $x]
		if {$verbose} {tclLog "  checking $tmp"}
		if {![file isdirectory $tmp]} break
		if {[lsearch $auto_path $tmp] < 0} {
		    if {$verbose} {tclLog "    inserted in auto_path."}
		    set auto_path [linsert $auto_path $pos $tmp]
		}
	    }
	}
    }
}
