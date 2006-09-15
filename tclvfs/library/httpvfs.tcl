
package provide vfs::http 0.6

package require vfs 1.0
package require http

# This works for basic operations, but has not been very debugged.

namespace eval vfs::http {
    # Allow for options when mounting an http URL
    variable options
    # -urlencode means automatically parse "foo/my file (2).txt" as
    # "foo/my%20file%20%282%29.txt", as per RFC 3986, for the user.
    set options(-urlencode) 1
    # -urlparse would further parse URLs for ? (query string) and # (anchor)
    # components, leaving those unencoded. Only works when -urlencode is true.
    set options(-urlparse) 0
}

proc vfs::http::Mount {dirurl local args} {
    ::vfs::log "http-vfs: attempt to mount $dirurl at $local (args: $args)"
    variable options
    foreach {key val} $args {
	# only do exact option name matching for now
	if {[info exists options($key)]} {
	    # currently only boolean values
	    if {![string is boolean -strict $val]} {
		return -code error "invalid boolean value \"$val\" for $key"
	    }
	    set options($key) $val
	}
    }
    if {[string index $dirurl end] ne "/"} {
	append dirurl "/"
    }
    if {[string match "http://*" $dirurl]} {
	set rest [string range $dirurl 7 end]
    } else {
	set rest $dirurl
	set dirurl "http://${dirurl}"
    }

    if {![regexp {(([^:]*)(:([^@]*))?@)?([^/]*)(/(.*/)?([^/]*))?$} $rest \
	      junk junk user junk pass host junk path file]} {
	return -code error "unable to parse url \"$dirurl\""
    }

    if {[string length $file]} {
	return -code error "Can only mount directories, not\
	  files (perhaps you need a trailing '/' - I understood\
	  a path '$path' and file '$file')"
    }

    if {$user eq ""} {
	set user anonymous
    }

    set token [::http::geturl $dirurl -validate 1]
    http::wait $token
    set status [http::status $token]
    http::cleanup $token
    if {$status ne "ok"} {
	# we'll take whatever http agrees is "ok"
	return -code error "received status \"$status\" for \"$dirurl\""
    }

    if {![catch {vfs::filesystem info $dirurl}]} {
	# unmount old mount
	::vfs::log "ftp-vfs: unmounted old mount point at $dirurl"
	vfs::unmount $dirurl
    }
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
    if {$cmd eq "matchindirectory"} {
	eval [linsert $args 0 $cmd $dirurl $relative $actualpath]
    } else {
	eval [linsert $args 0 $cmd $dirurl $relative]
    }
}

proc vfs::http::urlname {name} {
    # Parse the passed in name into a suitable URL name based on mount opts
    variable options
    if {$options(-urlencode)} {
	set querystr ""
	if {$options(-urlparse)} {
	    # check for ? and split if necessary so that the query_string
	    # part doesn't get encoded.  Anchors come after this as well.
	    set idx [string first ? $name]
	    if {$idx >= 0} {
		set querystr [string range $name $idx end] ; # includes ?
		set name [string range $name 0 [expr {$idx-1}]]
	    }
	}
	set urlparts [list]
	foreach part [file split $name] {
	    lappend urlparts [http::mapReply $part]
	}
	set urlname "[join $urlparts /]$querystr"
    } else {
	set urlname $name
    }
    return $urlname
}

# If we implement the commands below, we will have a perfect
# virtual file system for remote http sites.

proc vfs::http::stat {dirurl name} {
    set urlname [urlname $name]
    ::vfs::log "stat $name ($urlname)"

    # get information on the type of this file.  We describe everything
    # as a file (not a directory) since with http, even directories
    # really behave as the index.html they contain.

    set token [::http::geturl "$dirurl$urlname" -validate 1]
    http::wait $token
    set ncode [http::ncode $token]
    if {$ncode == 404 || [http::status $token] ne "ok"} {
	# 404 Not Found
	set code [http::code $token]
	http::cleanup $token
	vfs::filesystem posixerror $::vfs::posix(ENOENT)
	return -code error \
	    "could not read \"$name\": no such file or directory ($code)"
    }
    http::cleanup $token
    set mtime 0
    lappend res type file
    lappend res dev -1 uid -1 gid -1 nlink 1 depth 0 \
      atime $mtime ctime $mtime mtime $mtime mode 0777
    return $res
}

proc vfs::http::access {dirurl name mode} {
    set urlname [urlname $name]
    ::vfs::log "access $name $mode ($urlname)"
    if {$mode & 2} {
	vfs::filesystem posixerror $::vfs::posix(EROFS)
	return -code error "read-only"
    }
    if {$name == ""} { return 1 }
    set token [::http::geturl "$dirurl$urlname" -validate 1]
    http::wait $token
    set ncode [http::ncode $token]
    if {$ncode == 404 || [http::status $token] ne "ok"} {
	# 404 Not Found
	set code [http::code $token]
	http::cleanup $token
	vfs::filesystem posixerror $::vfs::posix(ENOENT)
	return -code error \
	    "could not read \"$name\": no such file or directory ($code)"
    } else {
	http::cleanup $token
	return 1
    }
}

# We've chosen to implement these channels by using a memchan.
# The alternative would be to use temporary files.
proc vfs::http::open {dirurl name mode permissions} {
    set urlname [urlname $name]
    ::vfs::log "open $name $mode $permissions ($urlname)"
    # return a list of two elements:
    # 1. first element is the Tcl channel name which has been opened
    # 2. second element (optional) is a command to evaluate when
    #    the channel is closed.
    switch -glob -- $mode {
	"" -
	"r" {
	    set token [::http::geturl "$dirurl$urlname"]

	    set filed [vfs::memchan]
	    fconfigure $filed -translation binary
	    http::wait $token
	    puts -nonewline $filed [::http::data $token]
	    http::cleanup $token

	    fconfigure $filed -translation auto
	    seek $filed 0
	    # XXX: the close command should free vfs::memchan somehow??
	    return [list $filed]
	}
	"a" -
	"w*" {
	    vfs::filesystem posixerror $::vfs::posix(EROFS)
	}
	default {
	    return -code error "illegal access mode \"$mode\""
	}
    }
}

proc vfs::http::matchindirectory {dirurl path actualpath pattern type} {
    ::vfs::log "matchindirectory $path $pattern $type"
    set res [list]

    if {[string length $pattern]} {
	# need to match all files in a given remote http site.
    } else {
	# single file
	if {![catch {access $dirurl $path 0}]} {
	    lappend res $path
	}
    }

    return $res
}

proc vfs::http::createdirectory {dirurl name} {
    ::vfs::log "createdirectory $name"
    vfs::filesystem posixerror $::vfs::posix(EROFS)
}

proc vfs::http::removedirectory {dirurl name recursive} {
    ::vfs::log "removedirectory $name"
    vfs::filesystem posixerror $::vfs::posix(EROFS)
}

proc vfs::http::deletefile {dirurl name} {
    ::vfs::log "deletefile $name"
    vfs::filesystem posixerror $::vfs::posix(EROFS)
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
	    vfs::filesystem posixerror $::vfs::posix(EROFS)
	}
    }
}

proc vfs::http::utime {dirurl path actime mtime} {
    vfs::filesystem posixerror $::vfs::posix(EROFS)
}

