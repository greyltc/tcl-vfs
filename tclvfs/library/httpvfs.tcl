
package require vfs 1.0
package require http

# THIS DOES NOT WORK!

# It's currently a copy of ftpvfs.tcl where there has basically been
# a global replacement of 'ftp' by 'http'.

namespace eval vfs::http {}

proc vfs::http::Mount {dirurl local} {
    ::vfs::log "http-vfs: attempt to mount $dirurl at $local"
    if {[string index $dirurl end] != "/"} {
	append dirurl "/"
    }
    if {[string range $dirurl 0 6] == "http://"} {
	set rest [string range $dirurl 7 end]
    } else {
	set rest $dirurl
	set dirurl "http://${dirurl}"
    }
    
    if {![regexp {(([^:]*)(:([^@]*))?@)?([^/]*)(/(.*/)?([^/]*))?$} $rest \
      junk junk user junk pass host junk path file]} {
	return -code error "Sorry I didn't understand\
	  the url address \"$dirurl\""
    }
    
    if {[string length $file]} {
	return -code error "Can only mount directories, not\
	  files (perhaps you need a trailing '/' - I understood\
	  a path '$path' and file '$file')"
    }
    
    if {![string length $user]} {
	set user anonymous
    }
    
    set token [::http::geturl $dirurl -validate 1]

    ::vfs::log "http $host, $path mounted at $local"
    vfs::filesystem mount $local [list vfs::http::handler $dirurl $path]
    # Register command to unmount
    vfs::RegisterMount $local [list ::vfs::http::Unmount $dirurl]
    return $dirurl
}

proc vfs::http::Unmount {dirurl local} {
    vfs::filesystem unmount $local
}

proc vfs::http::handler {dirurl path cmd root relative actualpath args} {
    if {$cmd == "matchindirectory"} {
	eval [list $cmd $dirurl $relative $actualpath] $args
    } else {
	eval [list $cmd $dirurl $relative] $args
    }
}

# If we implement the commands below, we will have a perfect
# virtual file system for remote http sites.

proc vfs::http::stat {dirurl name} {
    ::vfs::log "stat $name"
    
    # get information on the type of this file.  We describe everything
    # as a file (not a directory) since with http, even directories
    # really behave as the index.html they contain.
    set state [::http::geturl [file join $dirurl $name] -validate 1]
    set mtime 0
    lappend res type file
    lappend res dev -1 uid -1 gid -1 nlink 1 depth 0 \
      atime $mtime ctime $mtime mtime $mtime mode 0777
    return $res
}

proc vfs::http::access {dirurl name mode} {
    ::vfs::log "access $name $mode"
    if {$name == ""} { return 1 }
    set state [::http::geturl [file join $dirurl $name]]
    set info ""
    if {[string length $info]} {
	return 1
    } else {
	error "No such file"
    }
}

# We've chosen to implement these channels by using a memchan.
# The alternative would be to use temporary files.
proc vfs::http::open {dirurl name mode permissions} {
    ::vfs::log "open $name $mode $permissions"
    # return a list of two elements:
    # 1. first element is the Tcl channel name which has been opened
    # 2. second element (optional) is a command to evaluate when
    #    the channel is closed.
    switch -glob -- $mode {
	"" -
	"r" {
	    set state [::http::geturl [file join $dirurl $name]]
	    package require Memchan

	    set filed [memchan]
	    fconfigure $filed -translation binary
	    puts -nonewline $filed [::http::data $state]

	    fconfigure $filed -translation auto
	    seek $filed 0
	    return [list $filed]
	}
	"a" -
	"w*" {
	    error "Can't open $name for writing"
	}
	default {
	    return -code error "illegal access mode \"$mode\""
	}
    }
}

proc vfs::http::matchindirectory {dirurl path actualpath pattern type} {
    ::vfs::log "matchindirectory $path $pattern $type"
    set httpList [http::List $dirurl $path]
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

proc vfs::http::createdirectory {dirurl name} {
    ::vfs::log "createdirectory $name"
    error "read-only"
}

proc vfs::http::removedirectory {dirurl name} {
    ::vfs::log "removedirectory $name"
    error "read-only"
}

proc vfs::http::deletefile {dirurl name} {
    ::vfs::log "deletefile $name"
    error "read-only"
}

proc vfs::http::fileattributes {dirurl path args} {
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

proc vfs::http::utime {dirurl path actime mtime} {
    error "Can't set utime"
}

