
package require vfs 1.0
package require ftp

namespace eval vfs::ftp {}

proc vfs::ftp::Mount {dirurl local} {
    if {[string range $dirurl 0 5] == "ftp://"} {
	set dirurl [string range $dirurl 6 end]
    }
    regexp {(([^:]*)(:([^@]*))?@)?([^/]*)/(.*/)?([^/]*)$} $dirurl \
      junk junk user junk pass host path file
    
    if {[string length $file]} {
	return -code error "Can only mount directories, not\
	  files (perhaps you need a trailing '/')"
    }
    
    if {![string length $user]} {
	set user anonymous
    }
    
    set fd [::ftp::Open $host $user $pass $path]
    if {$fd == -1} {
	error "Mount failed"
    }
    if {[catch {
	::ftp::Cd $fd $path
    } err]} {
	ftp::Close $fd
	error "Opened ftp connection, but then received error: $err"
    }
    
    ::vfs::log "ftp $host, $path mounted at $fd"
    vfs::filesystem mount $local [list vfs::ftp::handler $fd $path]
    # Register command to unmount
    vfs::RegisterMount $local [list ::vfs::ftp::Unmount $fd]
    return $fd
}

proc vfs::ftp::Unmount {fd local} {
    vfs::filesystem unmount $local
    ::ftp::Close $fd
}

proc vfs::ftp::handler {fd path cmd root relative actualpath args} {
    if {$cmd == "matchindirectory"} {
	eval [list $cmd $fd $relative $actualpath] $args
    } else {
	eval [list $cmd $fd $relative] $args
    }
}

# If we implement the commands below, we will have a perfect
# virtual file system for remote ftp sites.

proc vfs::ftp::stat {fd name} {
    ::vfs::log "stat $name"
    if {$name == ""} {
	return [list type directory mtime 0 size 0 mode 0777 ino -1 \
	  depth 0 name "" dev -1 uid -1 gid -1 nlink 1]
    }
    
    # get information on the type of this file
    set ftpInfo [_findFtpInfo $fd $name]
    if {$ftpInfo == ""} { error "Couldn't find file info" }
    ::vfs::log $ftpInfo
    set perms [lindex $ftpInfo 0]
    if {[string index $perms 0] == "d"} {
	lappend res type directory
	set mtime 0
    } else {
	lappend res type file
	set mtime [ftp::ModTime $fd $name]
    }
    lappend res dev -1 uid -1 gid -1 nlink 1 depth 0 \
      atime $mtime ctime $mtime mtime $mtime mode 0777
    return $res
}

proc vfs::ftp::access {fd name mode} {
    ::vfs::log "access $name $mode"
    if {$name == ""} { return 1 }
    set info [vfs::ftp::_findFtpInfo $fd $name]
    if {[string length $info]} {
	return 1
    } else {
	error "No such file"
    }
}

# We've chosen to implement these channels by using a memchan.
# The alternative would be to use temporary files.
proc vfs::ftp::open {fd name mode permissions} {
    ::vfs::log "open $name $mode $permissions"
    # return a list of two elements:
    # 1. first element is the Tcl channel name which has been opened
    # 2. second element (optional) is a command to evaluate when
    #    the channel is closed.
    switch -glob -- $mode {
	"" -
	"r" {
	    ftp::Get $fd $name -variable tmp
	    package require Memchan

	    set filed [memchan]
	    fconfigure $filed -translation binary
	    puts -nonewline $filed $tmp

	    fconfigure $filed -translation auto
	    seek $filed 0
	    return [list $filed]
	}
	"a" {
	    # Try to append nothing to the file
	    if {[catch [list ::ftp::Append $fd -data "" $name] err] || !$err} {
		error "Can't open $name for appending"
	    }
	    package require Memchan
	    set filed [memchan]
	    return [list $filed [list ::vfs::ftp::_closing $fd $name $filed Append]]
	}
	"w*" {
	    # Try to write an empty file
	    if {[catch [list ::ftp::Put $fd -data "" $name] err] || !$err} {
		error "Can't open $name for writing"
	    }
	    package require Memchan
	    set filed [memchan]
	    return [list $filed [list ::vfs::ftp::_closing $fd $name $filed Put]]
	}
	default {
	    return -code error "illegal access mode \"$mode\""
	}
    }
}

proc vfs::ftp::_closing {fd name filed action} {
    seek $filed 0
    set contents [read $filed]
    if {![::ftp::$action $fd -data $contents $name]} {
	error "Failed to write to $name"
    }
}

proc vfs::ftp::_findFtpInfo {fd name} {
    ::vfs::log "findFtpInfo $fd $name"
    set ftpList [ftp::List $fd [file dirname $name]]
    foreach p $ftpList {
	regsub -all "\[ \t\]+" $p " " p
	set items [split $p " "]
	set pname [lindex $items end]
	if {$pname == [file tail $name]} {
	    return $items
	}
    }
    return ""
}

proc vfs::ftp::matchindirectory {fd path actualpath pattern type} {
    ::vfs::log "matchindirectory $path $pattern $type"
    set ftpList [ftp::List $fd $path]
    ::vfs::log "ftpList: $ftpList"
    set res [list]

    foreach p $ftpList {
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

proc vfs::ftp::createdirectory {fd name} {
    ::vfs::log "createdirectory $name"
    if {![ftp::MkDir $fd $name]} {
	error "failed"
    }
}

proc vfs::ftp::removedirectory {fd name} {
    ::vfs::log "removedirectory $name"
    if {![ftp::RmDir $fd $name]} {
	error "failed"
    }
}

proc vfs::ftp::deletefile {fd name} {
    ::vfs::log "deletefile $name"
    if {![ftp::Delete $fd $name]} {
	error "failed"
    }
}

proc vfs::ftp::fileattributes {fd path args} {
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
	}
    }
}

proc vfs::ftp::utime {fd path actime mtime} {
    error "Can't set utime"
}

