
package require vfs 1.0
package require ftp

namespace eval vfs::ftp {}

proc vfs::ftp::Mount {dirurl local} {
    regexp {(([^:]*)(:([^@]*))?@)?([^/]*)/(.*/)?([^/]*)$} $dirurl \
      junk junk user junk pass host path file
    
    set fd [::ftp::Open $host $user $pass $path]
    ::ftp::Cd $fd $path
    puts "ftp $host, $path mounted at $fd"
    vfs::filesystem mount $local [list vfs::ftp::handler $fd $path]
    return $fd
}

proc vfs::ftp::Unmount {fd} {
    ::ftp::Close $fd
}

proc vfs::ftp::handler {fd path cmd root relative actualpath args} {
    eval [list $cmd $fd $path $relative] $args
}

# If we implement the commands below, we will have a perfect
# virtual file system for remote ftp sites.

proc vfs::ftp::stat {fd path name} {
    puts "stat $name"
}

proc vfs::ftp::access {fd path name mode} {
    puts "access $name $mode"
}

proc vfs::ftp::open {fd name mode permissions} {
    puts "open $name $mode $permissions"
    # return a list of two elements:
    # 1. first element is the Tcl channel name which has been opened
    # 2. second element (optional) is a command to evaluate when
    #    the channel is closed.
    return [list]
}

proc vfs::ftp::matchindirectory {fd prefix path pattern type} {
    puts "matchindirectory $path $pattern $type"
    set ftpList [ftp::List $fd $path]
    puts "ftpList: $ftpList"
    set res [list]

    if {[::vfs::matchDirectories $type]} {
	# add matching directories to $res
    }
    
    if {[::vfs::matchFiles $type]} {
	# add matching files to $res
    }
    return $res
}

proc vfs::ftp::createdirectory {fd name} {
    puts "createdirectory $name"
}

proc vfs::ftp::removedirectory {fd name} {
    puts "removedirectory $name"
}

proc vfs::ftp::deletefile {fd name} {
    puts "deletefile $name"
}

proc vfs::ftp::fileattributes {fd path args} {
    puts "fileattributes $args"
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

