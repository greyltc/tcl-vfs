# The idea here is that we can mount 'ftp' or 'http' or 'file' types
# of urls and that (provided we have separate vfs types for them) we
# can then treat 'ftp://' as a mount point for ftp services.  For
# example, we can do:
#
# % vfs::urltype::Mount ftp
# Mounted at "ftp://"
# % cd ftp://
# % cd ftp.ucsd.edu   (or 'cd user:pass@ftp.foo.com')
# (This now creates an ordinary ftp-vfs for the remote site)
# ...
#
# Or all in one go:
# 
# % file copy ftp://ftp.ucsd.edu/pub/alpha/Readme .

namespace eval ::vfs::urltype {}

proc vfs::urltype::Mount {type} {
    # This requires Tcl 8.4a4.
    set mountPoint "${type}://"
    if {$type == "file"} {
	append mountPoint "/"
    }
    ::vfs::addVolume "${mountPoint}"
    ::vfs::filesystem mount $mountPoint [list vfs::urltype::handler $type]
    return "Mounted at \"${mountPoint}\""
}

proc vfs::urltype::handler {type cmd root relative actualpath args} {
    puts stderr [list $type $cmd $root $relative $actualpath $args]
    if {$cmd == "matchindirectory"} {
	eval [list $cmd $type $relative $actualpath] $args
    } else {
	eval [list $cmd $type $relative] $args
    }
}

# Stuff below not very well implemented.

proc vfs::urltype::stat {ns name} {
    ::vfs::log "stat $name"
    if {![string length $name]} {
	return [list type directory size 0 mode 0777 \
	  ino -1 depth 0 name $name atime 0 ctime 0 mtime 0 dev -1 \
	  uid -1 gid -1 nlink 1]
    } elseif {1} {
	return [list type file]
    } else {
	return -code error "could not read \"$name\": no such file or directory"
    }
}

proc vfs::urltype::access {ns name mode} {
    ::vfs::log "access $name $mode"
    if {![string length $name]} {
	return 1
    } elseif {1} {
	if {$mode & 2} {
	    error "read-only"
	}
	return 1
    } else {
	error "No such file"
    }
}

proc vfs::urltype::matchindirectory {ns path actualpath pattern type} {
    ::vfs::log "matchindirectory $path $actualpath $pattern $type"
    set res [list]

    return $res
}

proc vfs::urltype::createdirectory {ns name} {
    ::vfs::log "createdirectory $name"
    error ""
}

proc vfs::urltype::removedirectory {ns name} {
    ::vfs::log "removedirectory $name"
    error ""
}

proc vfs::urltype::deletefile {ns name} {
    ::vfs::log "deletefile $name"
    error ""
}

proc vfs::urltype::fileattributes {fd path args} {
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

proc vfs::urltype::utime {what name actime mtime} {
    ::vfs::log "utime $name"
    error ""
}
