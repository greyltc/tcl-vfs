
package require vfs 1.0
package require http

# THIS DOES NOT WORK!

# It's currently a copy of ftpvfs.tcl where there has basically been
# a global replacement of 'ftp' by 'http'.

namespace eval vfs::http {}

proc vfs::http::Mount {dirurl local} {
    if {[string range $dirurl 0 5] == "http://"} {
	set dirurl [string range $dirurl 6 end]
    }
    if {![regexp {(([^:]*)(:([^@]*))?@)?([^/]*)/(.*/)?([^/]*)$} $dirurl \
      junk junk user junk pass host path file]} {
	return -code error "Sorry I didn't understand\
	  the url address \"$dirurl\""
    }
    
    if {[string length $file]} {
	return -code error "Can only mount directories, not\
	  files (perhaps you need a trailing '/')"
    }
    
    if {![string length $user]} {
	set user anonymous
    }
    
    set fd [::http::Open $host $user $pass $path]
    if {$fd == -1} {
	error "Mount failed"
    }
    if {[catch {
	::http::Cd $fd $path
    } err]} {
	http::Close $fd
	error "Opened http connection, but then received error: $err"
    }
    
    ::vfs::log "http $host, $path mounted at $fd"
    vfs::filesystem mount $local [list vfs::http::handler $fd $path]
    # Register command to unmount
    vfs::RegisterMount $local [list ::vfs::http::Unmount $fd]
    return $fd
}

proc vfs::http::Unmount {fd local} {
    vfs::filesystem unmount $local
    ::http::Close $fd
}

proc vfs::http::handler {fd path cmd root relative actualpath args} {
    if {$cmd == "matchindirectory"} {
	eval [list $cmd $fd $relative $actualpath] $args
    } else {
	eval [list $cmd $fd $relative] $args
    }
}

# If we implement the commands below, we will have a perfect
# virtual file system for remote http sites.

proc vfs::http::stat {fd name} {
    ::vfs::log "stat $name"
    if {$name == ""} {
	return [list type directory mtime 0 size 0 mode 0777 ino -1 \
	  depth 0 name "" dev -1 uid -1 gid -1 nlink 1]
    }
    
    # get information on the type of this file
    set httpInfo [_findHttpInfo $fd $name]
    if {$httpInfo == ""} { error "Couldn't find file info" }
    ::vfs::log $httpInfo
    set perms [lindex $httpInfo 0]
    if {[string index $perms 0] == "d"} {
	lappend res type directory
	set mtime 0
    } else {
	lappend res type file
	set mtime [http::ModTime $fd $name]
    }
    lappend res dev -1 uid -1 gid -1 nlink 1 depth 0 \
      atime $mtime ctime $mtime mtime $mtime mode 0777
    return $res
}

proc vfs::http::access {fd name mode} {
    ::vfs::log "access $name $mode"
    if {$name == ""} { return 1 }
    set info [vfs::http::_findHttpInfo $fd $name]
    if {[string length $info]} {
	return 1
    } else {
	error "No such file"
    }
}

# We've chosen to implement these channels by using a memchan.
# The alternative would be to use temporary files.
proc vfs::http::open {fd name mode permissions} {
    ::vfs::log "open $name $mode $permissions"
    # return a list of two elements:
    # 1. first element is the Tcl channel name which has been opened
    # 2. second element (optional) is a command to evaluate when
    #    the channel is closed.
    switch -glob -- $mode {
	"" -
	"r" {
	    http::Get $fd $name -variable tmp
	    package require Memchan

	    set filed [memchan]
	    fconfigure $filed -translation binary
	    puts -nonewline $filed $tmp

	    fconfigure $filed -translation auto
	    seek $filed 0
	    return [list $filed]
	}
	"a" -
	"w*" {
	    # Try to write an empty file
	    error "Can't open $name for writing"
	}
	default {
	    return -code error "illegal access mode \"$mode\""
	}
    }
}

proc vfs::http::_findHttpInfo {fd name} {
    ::vfs::log "findHttpInfo $fd $name"
    set httpList [http::List $fd [file dirname $name]]
    foreach p $httpList {
	regsub -all "\[ \t\]+" $p " " p
	set items [split $p " "]
	set pname [lindex $items end]
	if {$pname == [file tail $name]} {
	    return $items
	}
    }
    return ""
}

proc vfs::http::matchindirectory {fd path actualpath pattern type} {
    ::vfs::log "matchindirectory $path $pattern $type"
    set httpList [http::List $fd $path]
    ::vfs::log "httpList: $httpList"
    set res [list]

    foreach p $httpList {
	regsub -all "\[ \t\]+" $p " " p
	set items [split $p " "]
	set name [lindex $items end]
	set perms [lindex $items 0]
	if {[::vfs::matchDirectories $type]} {
	    if {[string index $perms 0] == "d"} {
		lappend res "$actualpath$name"
	    }
	}
	if {[::vfs::matchFiles $type]} {
	    if {[string index $perms 0] != "d"} {
		lappend res "$actualpath$name"
	    }
	}
	
    }
 
    return $res
}

proc vfs::http::createdirectory {fd name} {
    ::vfs::log "createdirectory $name"
    error "read-only"
}

proc vfs::http::removedirectory {fd name} {
    ::vfs::log "removedirectory $name"
    error "read-only"
}

proc vfs::http::deletefile {fd name} {
    ::vfs::log "deletefile $name"
    error "read-only"
}

proc vfs::http::fileattributes {fd path args} {
    ::vfs::log "fileattributes $args"
    switch -- [llength $args] {
	0 {
	    # list strings
	    return [list]
	}
	1 {
	    # get value
	    set index [lindex $args 0]
	}
	2 {
	    # set value
	    set index [lindex $args 0]
	    set val [lindex $args 1]
	    error "read-only"
	}
    }
}

proc vfs::http::utime {fd path actime mtime} {
    error "Can't set utime"
}

