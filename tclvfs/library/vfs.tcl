# Only useful for TclKit
# (this file is included in tclvfs so this entire package can be
# use in tclkit if desired).
#
# Initialization script normally executed in the interpreter for each
# VFS-based application.
#
# Copyright (c) 1999  Matt Newman <matt@sensus.org>
# Further changes made by Jean-Claude Wippler <jcw@equi4.com>
# Further changes made by Vince Darley <vince.darley@eurobios.com>
#
# See the file "license.terms" for information on usage and redistribution
# of this file, and for a DISCLAIMER OF ALL WARRANTIES.

# Insist on running with compatible version of Tcl.
package require Tcl 8.4
package provide vfslib 0.1

# So I can debug on command line when starting up Tcl from a vfs
# when I might not have the history procedures loaded yet!
#proc history {args} {}

lappend auto_path [file dirname [info script]]

# This stuff is for TclKit
namespace eval ::vfs {
    variable temp
    global env

    set temp [file nativename /usr/tmp]
    if {![file exists $temp]} {set temp [file nativename /tmp]}
    catch {set temp $env(TMP)}
    catch {set temp $env(TMPDIR)}
    catch {set temp $env(SYSTEMDRIVE)/temp}
    catch {set temp $env(TEMP)}
    catch {set temp $env(VFS_TEMP)}
    set temp [file join $temp tclkit]
    file mkdir $temp

    # This is not right XXX need somewhere to unpack
    # indirect-dependant DLL's etc.

    global env tcl_platform
    if {$tcl_platform(platform) == "windows"} {
	set env(PATH) "${vfs::temp}/bin;$env(PATH)"
    } elseif {$tcl_platform(platform) == "unix"} {
	set env(PATH) "${vfs::temp}/bin:$env(PATH)"
    } else {
	set env(PATH) "${vfs::temp}/bin"
    }
    proc debug {tag body} {
	set cnt [info cmdcount]
	set time [lindex [time {
	    set rc [catch {uplevel 1 [list eval $body]} ret]
	}] 0]
	set cnt' [info cmdcount]
	set ei ${::errorInfo}
	set ec ${::errorCode}
	puts stderr "$tag: [expr {${cnt'} - $cnt}] ops, $time us"
	return -code $rc -errorcode $ec -errorinfo $ei $ret
    }
}
