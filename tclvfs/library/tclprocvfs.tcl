
package require vfs 1.0

# Thanks to jcw for the idea here.  This is a 'file system' which
# is actually a representation of the Tcl command namespace hierarchy.
# Namespaces are directories, and procedures are files.  Tcl allows
# procedures with the same name as a namespace, which are hidden in
# a filesystem representation.

namespace eval vfs::tclproc {}

proc vfs::tclproc::Mount {ns local} {
    if {![namespace exists ::$ns]} {
	error "No such namespace"
    }
    puts "tclproc $ns mounted at $local"
    vfs::filesystem mount $local [list vfs::tclproc::handler $ns]
    vfs::RegisterMount $local [list vfs::tclproc::Unmount]
}

proc vfs::tclproc::Unmount {local} {
    vfs::filesystem unmount $local
}

proc vfs::tclproc::handler {ns cmd root relative actualpath args} {
    regsub -all / $relative :: relative
    if {$cmd == "matchindirectory"} {
	eval [list $cmd $ns $relative $actualpath] $args
    } else {
	eval [list $cmd $ns $relative] $args
    }
}

# If we implement the commands below, we will have a perfect
# virtual file system for remote tclproc sites.

proc vfs::tclproc::stat {ns name} {
    puts stderr "stat $name"
    if {[namespace exists ::${ns}::${name}]} {
	puts "directory"
	return [list type directory size 0 mode 0777 \
	  ino -1 depth 0 name $name atime 0 ctime 0 mtime 0 dev -1 \
	  uid -1 gid -1 nlink 1]
    } elseif {[llength [info procs ::${ns}::${name}]]} {
	puts "file"
	return [list type file]
    } else {
	return -code error "could not read \"$name\": no such file or directory"
    }
}

proc vfs::tclproc::access {ns name mode} {
    puts stderr "access $name $mode"
    if {[namespace exists ::${ns}::${name}]} {
	return 1
    } elseif {[llength [info procs ::${ns}::${name}]]} {
	if {$mode & 2} {
	    error "read-only"
	}
	return 1
    } else {
	error "No such file"
    }
}

proc vfs::tclproc::exists {ns name} {
    if {[namespace exists ::${ns}::${name}]} {
	return 1
    } elseif {[llength [info procs ::${ns}::${name}]]} {
	return 1
    } else {
	return 0
    }
}

proc vfs::tclproc::open {ns name mode permissions} {
    puts stderr "open $name $mode $permissions"
    # return a list of two elements:
    # 1. first element is the Tcl channel name which has been opened
    # 2. second element (optional) is a command to evaluate when
    #    the channel is closed.
    switch -- $mode {
	"" -
	"r" {
	    package require Memchan

	    set nfd [memchan]
	    fconfigure $nfd -translation binary
	    puts -nonewline $nfd [_generate ::${ns}::${name}]
	    fconfigure $nfd -translation auto
	    seek $nfd 0
	    return [list $nfd]
	}
	default {
	    return -code error "illegal access mode \"$mode\""
	}
    }
}

proc vfs::tclproc::_generate {p} {
    lappend a proc $p
    set argslist [list]
    foreach arg [info args $p] {
	if {[info default $p $arg v]} {
	    lappend argslist [list $arg $v]
	} else {
	    lappend argslist $arg
	}
    }
    lappend a $argslist [info body $p]
}

proc vfs::tclproc::matchindirectory {ns path actualpath pattern type} {
    puts stderr "matchindirectory $path $actualpath $pattern $type"
    set res [list]

    if {[::vfs::matchDirectories $type]} {
	# add matching directories to $res
	eval lappend res [namespace children ::${ns}::${path} $pattern]
    }
    
    if {[::vfs::matchFiles $type]} {
	# add matching files to $res
	eval lappend res [info procs ::${ns}::${path}::$pattern]
    }
    set realres [list]
    foreach r $res {
	regsub "^(::)?${ns}(::)?${path}(::)?" $r $actualpath rr
	lappend realres $rr
    }
    #puts $realres
    
    return $realres
}

proc vfs::tclproc::createdirectory {ns name} {
    puts stderr "createdirectory $name"
    namespace eval ::${ns}::${name} {}
}

proc vfs::tclproc::removedirectory {ns name} {
    puts stderr "removedirectory $name"
    namespace delete ::${ns}::${name}
}

proc vfs::tclproc::deletefile {ns name} {
    puts stderr "deletefile $name"
    rename ::${ns}::${name} {}
}

proc vfs::tclproc::fileattributes {ns name args} {
    puts stderr "fileattributes $args"
    switch -- [llength $args] {
	0 {
	    # list strings
	    return [list -args -body]
	}
	1 {
	    # get value
	    set index [lindex $args 0]
	    switch -- $index {
		0 {
		    ::info args ::${ns}::${name}
		}
		1 {
		    ::info body ::${ns}::${name}
		}
	    }
	}
	2 {
	    # set value
	    set index [lindex $args 0]
	    set val [lindex $args 1]
	    switch -- $index {
		0 {
		    error "read-only"
		}
		1 {
		    error "unimplemented"
		}
	    }
	}
    }
}

proc vfs::tclproc::utime {what name actime mtime} {
    puts stderr "utime $name"
    error ""
}
