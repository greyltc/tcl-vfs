
package require vfs

proc ::vfs::autoMountExtension {ext cmd {pkg ""}} {
    variable extMounts
    set extMounts($ext) [list $cmd $pkg]
}

proc ::vfs::autoMountUrl {type cmd {pkg ""}} {
    variable urlMounts
    set urlMounts($type) [list $cmd $pkg]
}

::vfs::autoMountExtension .zip ::vfs::zip::Mount vfs
::vfs::autoMountUrl ftp ::vfs::ftp::Mount vfs
::vfs::autoMountUrl file ::vfs::fileUrlMount vfs
::vfs::autoMountUrl tclns ::vfs::tclprocMount vfs

proc ::vfs::haveMount {url} {
    variable mounted
    info exists mounted($url)
}

proc ::vfs::urlMount {url args} {
    puts "$url $args"
    variable urlMounts
    if {[regexp {^([a-zA-Z]+)://(.*)} $url "" urltype rest]} {
	if {[info exists urlMounts($urltype)]} {
	    #::vfs::log "automounting $path"
	    foreach {cmd pkg} $urlMounts($urltype) {}
	    if {[string length $pkg]} {
		package require $pkg
	    }
	    eval $cmd [list $url] $args
	    variable mounted
	    set mounted($url) 1
	    return
	}
	error "Unknown url type '$urltype'"
    }
    error "Couldn't parse url $url"
}

proc ::vfs::fileUrlMount {url args} {
    # Strip off the leading 'file://'
    set file [string range $url 7 end]
    eval [list ::vfs::auto $file] $args
}

proc ::vfs::tclprocMount {url args} {
    # Strip off the leading 'tclns://'
    set ns [string range $url 8 end]
    eval [list ::vfs::tclproc::Mount $ns] $args
}

proc ::vfs::auto {filename args} {
    variable extMounts
    
    set np {}

    set split [::file split $filename]
    
    foreach ele $split {
	lappend np $ele
	set path [::file normalize [eval [list ::file join] $np]]
	if {[::file isdirectory $path]} {
	    # already mounted
	    continue
	} elseif {[::file isfile $path]} {
	    set ext [string tolower [::file extension $ele]]
	    if {[::info exists extMounts($ext)]} {
		#::vfs::log "automounting $path"
		foreach {cmd pkg} $extMounts($ext) {}
		if {[string length $pkg]} {
		    package require $pkg
		}
		eval $cmd [list $path $path] $args
	    } else {
		continue
	    }
	} else {
	    # It doesn't exist, so just return
	    # return -code error "$path doesn't exist"
	    return
	}
    }
}

# Helper procedure for vfs matchindirectory
# implementations.  It is very important that
# we match properly when given 'directory'
# specifications, since this is used for
# recursive globbing by Tcl.
proc vfs::matchCorrectTypes {types filelist} {
    if {$types != 0} {
	# Which types to return.  We must do special
	# handling of directories and files.
	set file [matchFiles $types]
	set dir [matchDirectories $types]
	if {$file && $dir} {
	    return $filelist
	}
	if {$file == 0 && $dir == 0} {
	    return [list]
	}
	set newres [list]
	if {$file} {
	    foreach r $filelist {
		if {[::file isfile $r]} {
		    lappend newres $r
		}
	    }
	} else {
	    foreach r $filelist {
		if {[::file isdirectory $r]} {
		    lappend newres $r
		}
	    }
	}
	set filelist $newres
    }
    return $filelist
}

# Convert integer mode to a somewhat preferable string.
proc vfs::accessMode {mode} {
    lindex [list F X W XW R RX RW] $mode
}

proc vfs::matchDirectories {types} {
    return [expr {$types == 0 ? 1 : $types & (1<<2)}]
}

proc vfs::matchFiles {types} {
    return [expr {$types == 0 ? 1 : $types & (1<<4)}]
}

proc vfs::modeToString {mode} {
}
