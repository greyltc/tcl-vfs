#
# Copyright (C) 1997-1999 Sensus Consulting Ltd. All Rights Reserved.
# Matt Newman <matt@sensus.org> and Jean-Claude Wippler <jcw@equi4.com>
#
# $Header$
#

###############################################################################
# use Pink for zip and md5 replacements, this avoids the dependency on Trf

    package ifneeded Trf 1.3 {
    
        package require pink
        package provide Trf 1.3
    
        proc zip {flag value data} {
            switch -glob -- "$flag $value" {
            {-mode d*} {
                set mode decompress
            }
            {-mode c*} {
                set mode compress
            }
            default {
                error "usage: zip -mode {compress|decompress} data"
            }
            }
            return [pink zlib $mode $data]
        }
    
        proc crc {data} {
            return [pink zlib crc32 $data]
        }
    
        proc md5 {data} {
            set cmd [pink md5]
            $cmd update $data
            set result [$cmd digest]
            rename $cmd ""
            return $result
        }
    }

###############################################################################
# this replacement is for memchan, used for simple (de)compression

    package ifneeded memchan 0.1 {
    
	    package require rechan
	    package provide memchan 0.1
	
	    proc _memchan_handler {cmd fd args} {
	        upvar #0 ::_memchan_buf($fd) _buf
	        upvar #0 ::_memchan_pos($fd) _pos
	        set arg1 [lindex $args 0]
	        
	        switch -- $cmd {
	            seek {
	                switch $args {
	                    1 { incr arg1 $_pos }
	                    2 { incr arg1 [string length $_buf]}
	                }
	                return [set _pos $arg1]
	            }
	            read {
	                set r [string range $_buf $_pos [expr { $_pos + $arg1 - 1 }]]
	                incr _pos [string length $r]
	                return $r
	            }
	            write {
	                set n [string length $arg1]
	                if { $_pos >= [string length $_buf] } {
	                    append _buf $arg1
	                } else { # the following doesn't work yet :(
	                    set last [expr { $_pos + $n - 1 }]
	                    set _buf [string replace $_buf $_pos $last $arg1]
			    error "mk4vfs: sorry no inline write yet"
	                }
	                incr _pos $n
	                return $n
	            }
	            close {
	                unset _buf _pos
	            }
		    default {
			error "Bad call to memchan replacement handler: $cmd"
		    }
	        }
	    }
	    
	    proc memchan {} {
	        set fd [rechan _memchan_handler 6]
	        #fconfigure $fd -translation binary -encoding binary
	        
	        set ::_memchan_buf($fd) ""
	        set ::_memchan_pos($fd) 0
	        
	        return $fd
	    }
	}
        
###############################################################################

namespace eval vfs::mk4 {}

proc vfs::mk4::Mount {what local args} {
    set db [eval [list ::mk4vfs::_mount $what $local] $args]

    ::vfs::filesystem mount $what [list ::vfs::mk4::handler $db]
    # Register command to unmount
    ::vfs::RegisterMount $local [list ::vfs::mk4::Unmount $db]
    return $db
}

proc mk4vfs::mount {args} {
    uplevel 1 [list ::vfs::mk4::mount] $args
}

proc vfs::mk4::Unmount {db local} {
    vfs::filesystem unmount $local
    ::mk4vfs::umount $db
}

proc vfs::mk4::handler {db cmd root relative actualpath args} {
    #tclLog [list $db $cmd $root $relative $actualpath $args]
    if {$cmd == "matchindirectory"} {
	eval [list $cmd $db $relative $actualpath] $args
    } elseif {$cmd == "fileattributes"} {
	eval [list $cmd $db $root $relative] $args
    } else {
	eval [list $cmd $db $relative] $args
    }
}

proc vfs::mk4::utime {db path actime modtime} {
    #::vfs::log [list utime $path]
    ::mk4vfs::stat $db $path sb
    
    if { $sb(type) == "file" } {
	::mk::set $sb(ino) date $modtime
    }
}

# If we implement the commands below, we will have a perfect
# virtual file system for zip files.

proc vfs::mk4::matchindirectory {db path actualpath pattern type} {
    #::vfs::log [list matchindirectory $path $actualpath $pattern $type]
    set res [::mk4vfs::getdir $db $path $pattern]
    #::vfs::log "got $res"
    set newres [list]
    foreach p [::vfs::matchCorrectTypes $type $res $actualpath] {
	lappend newres "$actualpath$p"
    }
    #::vfs::log "got $newres"
    return $newres
}

proc vfs::mk4::stat {db name} {
    #::vfs::log "stat $name"
    ::mk4vfs::stat $db $name sb
    #::vfs::log [array get sb]

    # for new vfs:
    set sb(dev) 0
    set sb(ino) 0
    array get sb
}

proc vfs::mk4::access {db name mode} {
    #::vfs::log "mk4-access $name $mode"
    # This needs implementing better.  
    #tclLog "mk4vfs::driver $db access $name $mode"
    switch -- $mode {
	0 {
	    # exists
	    if {![catch {::mk4vfs::stat $db $name sb}]} {
		return
	    }
	}
	1 {
	    # executable
	    if {![catch {::mk4vfs::stat $db $name sb}]} {
		return
	    }
	}
	2 {
	    # writable
	    if {![catch {::mk4vfs::stat $db $name sb}]} {
		return
	    }
	}
	4 {
	    # readable
	    if {![catch {::mk4vfs::stat $db $name sb}]} {
		return
	    }
	}
    }
    #tclLog "access bad"
    error "bad file" 
}

proc vfs::mk4::open {db file mode permissions} {
    #::vfs::log "open $file $mode $permissions"
    # return a list of two elements:
    # 1. first element is the Tcl channel name which has been opened
    # 2. second element (optional) is a command to evaluate when
    #    the channel is closed.
    switch -glob -- $mode {
	{}  -
	r   {
	    ::mk4vfs::stat $db $file sb
	
	    if { $sb(csize) != $sb(size) } {
		package require Trf
		package require memchan
		#tclLog "$file: decompressing on read"

		set fd [memchan]
		fconfigure $fd -translation binary
		set s [mk::get $sb(ino) contents]
		puts -nonewline $fd [zip -mode decompress $s]

		fconfigure $fd -translation auto
		seek $fd 0
		return [list $fd [list _memchan_handler close $fd]]
	    } elseif { $::mk4vfs::direct } {
		package require Trf
		package require memchan

		set fd [memchan]
		fconfigure $fd -translation binary
		puts -nonewline $fd [mk::get $sb(ino) contents]

		fconfigure $fd -translation auto
		seek $fd 0
		return [list $fd [list _memchan_handler close $fd]]
	    } else {
		set fd [mk::channel $sb(ino) contents r]
	    }
	    return [list $fd]
	}
	a   {
	    if { [catch {::mk4vfs::stat $db $file sb }] } {
		#tclLog "stat failed - creating $file"
		# Create file
		::mk4vfs::stat $db [file dirname $file] sb

		set cur [mk::row append $sb(ino).files name [file tail $file] size 0 date [clock seconds] ]
		set sb(ino) $cur

		if { [string match *z* $mode] || ${mk4vfs::compress} } {
		    set sb(csize) -1    ;# HACK - force compression
		} else {
		    set sb(csize) 0
		}
	    }

	    if { $sb(csize) != $sb(size) } {
		package require Trf
		package require memchan

		#tclLog "$file: compressing on append"
		append mode z
		set fd [memchan]

		fconfigure $fd -translation binary
		set s [mk::get $sb(ino) contents]
		puts -nonewline $fd [zip -mode decompress $s]
		fconfigure $fd -translation auto
	    } else {
		set fd [mk::channel $sb(ino) contents a]
	    }
	    return [list $fd [list mk4vfs::do_close $fd $mode $sb(ino)]]
	}
	w*  {
	    if { [catch {::mk4vfs::stat $db $file sb }] } {
		#tclLog "stat failed - creating $file"
		# Create file
		::mk4vfs::stat $db [file dirname $file] sb
		set cur [mk::row append $sb(ino).files name [file tail $file] size 0 date [clock seconds] ]
		set sb(ino) $cur
	    }
	    if { [string match *z* $mode] || ${mk4vfs::compress} } {
		package require Trf
		package require memchan
		#tclLog "$file: compressing on write"
		###zip -attach $fd -mode compress
		append mode z
		set fd [memchan]
	    } else {
		set fd [mk::channel $sb(ino) contents w]
	    }
	    return [list $fd [list mk4vfs::do_close $fd $mode $sb(ino)]]
	}
	default     {
	    error "illegal access mode \"$mode\""
	}
    }
}

proc vfs::mk4::createdirectory {db name} {
    #::vfs::log "createdirectory $name"
    mk4vfs::mkdir $db $name
}

proc vfs::mk4::removedirectory {db name} {
    #::vfs::log "removedirectory $name"
    mk4vfs::delete $db $name
}

proc vfs::mk4::deletefile {db name} {
    #::vfs::log "deletefile $name"
    mk4vfs::delete $db $name
}

proc vfs::mk4::fileattributes {db root relative args} {
    #::vfs::log "fileattributes $args"
    switch -- [llength $args] {
	0 {
	    # list strings
	    return [::vfs::listAttributes]
	}
	1 {
	    # get value
	    set index [lindex $args 0]
	    return [::vfs::attributesGet $root $relative $index]

	}
	2 {
	    # set value
	    set index [lindex $args 0]
	    set val [lindex $args 1]
	    return [::vfs::attributesSet $root $relative $index $val]
	}
    }
}

package require Mk4tcl
package require vfs
package require vfslib

package provide mk4vfs 1.0

namespace eval mk4vfs {
    variable uid 0
    variable compress 1         ;# HACK - needs to be part of "Super-Block"
    variable flush      5000    ;# Auto-Commit frequency
    variable direct 0

    namespace export mount umount
}

proc mk4vfs::init {db} {
    mk::view layout $db.dirs {name:S parent:I {files {name:S size:I date:I contents:M}}}

    if { [mk::view size $db.dirs] == 0 } {
        mk::row append $db.dirs name <root> parent 0
    }
}

proc mk4vfs::_mount {path file args} {
    variable uid
    set db mk4vfs[incr uid]

    eval [list mk::file open $db $file] $args

    init $db

    set flush 1
    for {set idx 0} {$idx < [llength $args]} {incr idx} {
        switch -- [lindex $args $idx] {
        -readonly       -
        -nocommit       {set flush 0}
        }
    }
    if { $flush } {
        _commit $db
    }
    return $db
}

proc mk4vfs::_commit {db} {
    after ${::mk4vfs::flush} [list mk4vfs::_commit $db]
    mk::file commit $db
}

proc mk4vfs::umount {db} {
    tclLog [list unmount $db]
    mk::file close $db
}

proc mk4vfs::stat {db path arr} {
    variable cache
    
    #set pre [array names cache]
    
    upvar 1 $arr sb
    #tclLog "mk4vfs::stat $db $path $arr"

    set sp [::file split $path]
    set tail [lindex $sp end]

    set parent 0
    set view $db.dirs
    set cur $view!$parent
    set type directory

    foreach ele [lrange $sp 0 [expr { [llength $sp] - 2 }]] {

        if { [info exists cache($cur,$ele)] } {
            set parent $cache($cur,$ele)
        } else {
            #set row [mk::select $view name $ele parent $parent]
            set row [find/dir $view $ele $parent]

            if { $row == -1 } {
                #tclLog "select failed: parent $parent name $ele"
                return -code error "could not read \"$path\": no such file or directory"
            }
	    set parent $row
            set cache($cur,$ele) $parent
        }
	set cur $view!$parent
	#mk::cursor position cur $parent
    }
    #
    # Now check if final comp is a directory or a file
    #
    # CACHING is required - it can deliver a x15 speed-up!
    #
    if { [string equal $tail "."] || [string equal $tail ":"] || [string equal $tail ""] } {
	# donothing

    } elseif { [info exists cache($cur,$tail)] } {
        set type directory
        #set cur $view!$cache($cur,$tail)
	mk::cursor position cur $cache($cur,$tail)

    } else {
        # File?
        #set row [mk::select $cur.files name $tail]
        set row [find/file $cur.files $tail]

        if { $row != -1 } {
            set type file
            set view $cur.files
	    #set cur $view!$row
	    mk::cursor create cur $view $row

        } else {
            # Directory?
            #set row [mk::select $view parent $parent name $tail]
            set row [find/dir $view $tail $parent]

            if { $row != -1 } {
                set type directory
		#set cur $view!$row
		# MUST SET cache BEFORE calling mk::cursor!!!
		set cache($cur,$tail) $row
		mk::cursor position cur $row
            } else { 
                return -code error "could not read \"$path\": no such file or directory"
            }
        }
    }
    set sb(type)	$type
    set sb(view)	$view
    set sb(ino)		$cur
    set sb(dev)		[list mk4vfs::driver $db]

    if { [string equal $type "directory"] } {
        set sb(atime)   0
        set sb(ctime)   0
	set sb(gid)	0
        set sb(mode)    0777
        set sb(mtime)   0
        set sb(nlink)   [expr { [mk::get $cur files] + 1 }]
        set sb(size)    0
        set sb(csize)   0
	set sb(uid)	0
    } else {
        set mtime	[mk::get $cur date]
        set sb(atime)	$mtime
        set sb(ctime)	$mtime
	set sb(gid)	0
        set sb(mode)    0777
        set sb(mtime)	$mtime
        set sb(nlink)   1
        set sb(size)    [mk::get $cur size]
        set sb(csize)   [mk::get $cur -size contents]
	set sb(uid)	0
    }
    
    #foreach n [array names cache] {
    #if {[lsearch -exact $pre $n] == -1} {
    #::vfs::log "added $path $n $cache($n)"
    #}
    #}
}

proc mk4vfs::driver {db option args} {
    #tclLog "mk4vfs::driver $db $option $args"
    switch -- $option {
    lstat       {return [uplevel 1 [concat [list mk4vfs::stat $db] $args]]}
    chdir       {return [lindex $args 0]}
    access      {
	# This needs implementing better.  The 'lindex $args 1' is
	# the access mode we should be checking.
	set mode [lindex $args 1]
	#tclLog "mk4vfs::driver $db access [lindex $args 0] $mode"
	switch -- $mode {
	    0 {
		# exists
		if {![catch {stat $db [lindex $args 0] sb}]} {
		    return
		}
	    }
	    1 {
		# executable
		if {![catch {stat $db [lindex $args 0] sb}]} {
		    return
		}
	    }
	    2 {
		# writable
		if {![catch {stat $db [lindex $args 0] sb}]} {
		    return
		}
	    }
	    4 {
		# readable
		if {![catch {stat $db [lindex $args 0] sb}]} {
		    return
		}
	    }
	}
	#tclLog "access bad"
	error "bad file" 
    }
    removedirectory {
	return [uplevel 1 [concat [list mk4vfs::delete $db] $args]]
    }
    atime       {
	# Not implemented
    }
    mtime       -
    delete      -
    stat        -
    getdir      -
    mkdir       {return [uplevel 1 [concat [list mk4vfs::$option $db] $args]]}
    
    open        {
            set file [lindex $args 0]
            set mode [lindex $args 1]

            switch -glob -- $mode {
            {}  -
            r   {
                    stat $db $file sb
                
                    if { $sb(csize) != $sb(size) } {
                        package require Trf
                        package require memchan
                        #tclLog "$file: decompressing on read"

                        set fd [memchan]
                        fconfigure $fd -translation binary
                        set s [mk::get $sb(ino) contents]
                        puts -nonewline $fd [zip -mode decompress $s]

                        fconfigure $fd -translation auto
                        seek $fd 0
			return [list $fd [list _memchan_handler close $fd]]
                    } elseif { $::mk4vfs::direct } {
                        package require Trf
                        package require memchan

                        set fd [memchan]
                        fconfigure $fd -translation binary
                        puts -nonewline $fd [mk::get $sb(ino) contents]

                        fconfigure $fd -translation auto
                        seek $fd 0
			return [list $fd [list _memchan_handler close $fd]]
		    } else {
			set fd [mk::channel $sb(ino) contents r]
                    }
		    return [list $fd]
                }
            a   {
                    if { [catch {stat $db $file sb }] } {
                        #tclLog "stat failed - creating $file"
                        # Create file
                        stat $db [file dirname $file] sb

                        set cur [mk::row append $sb(ino).files name [file tail $file] size 0 date [clock seconds] ]
                        set sb(ino) $cur

                        if { [string match *z* $mode] || ${mk4vfs::compress} } {
                            set sb(csize) -1    ;# HACK - force compression
                        } else {
                            set sb(csize) 0
                        }
                    }

                    if { $sb(csize) != $sb(size) } {
                        package require Trf
                        package require memchan

                        #tclLog "$file: compressing on append"
                        append mode z
                        set fd [memchan]

                        fconfigure $fd -translation binary
                        set s [mk::get $sb(ino) contents]
                        puts -nonewline $fd [zip -mode decompress $s]
                        fconfigure $fd -translation auto
                    } else {
			set fd [mk::channel $sb(ino) contents a]
                    }
                    return [list $fd [list mk4vfs::do_close $fd $mode $sb(ino)]]
                }
            w*  {
                    if { [catch {stat $db $file sb }] } {
                        #tclLog "stat failed - creating $file"
                        # Create file
                        stat $db [file dirname $file] sb
                        set cur [mk::row append $sb(ino).files name [file tail $file] size 0 date [clock seconds] ]
                        set sb(ino) $cur
                    }
                    if { [string match *z* $mode] || ${mk4vfs::compress} } {
                        package require Trf
                        package require memchan
                        #tclLog "$file: compressing on write"
                        ###zip -attach $fd -mode compress
                        append mode z
                        set fd [memchan]
                    } else {
	                    set fd [mk::channel $sb(ino) contents w]
                    }
                    return [list $fd [list mk4vfs::do_close $fd $mode $sb(ino)]]
                }
            default     {
                    error "illegal access mode \"$mode\""
                }
            }
        }
    sync        {eval [list mk::file commit $db] [lrange $args 1 end]}
    umount      {eval [list mk::file close $db] $args}
    default     {
            return -code error "bad option \"$option\": must be one of chdir, delete, getdir, load, lstat, mkdir, open, stat, sync, or umount"
        }
    }
}

proc mk4vfs::do_close {fd mode cur} {
    # Set size to -1 before the seek - just in case it fails.
    
    if {[catch {
	set iswrite [regexp {[aw]} $mode]
	    
	if {$iswrite} {
	    mk::set $cur size -1 date [clock seconds]
	    flush $fd
	    if { [string match *z* $mode] } {
		fconfigure $fd -translation binary
		seek $fd 0
		set data [read $fd]
		_memchan_handler close $fd
		set cdata [zip -mode compress $data]
		set len [string length $data]
		set clen [string length $cdata]
		if { $clen < $len } {
		    mk::set $cur size $len contents $cdata
		} else {
		    mk::set $cur size $len contents $data
		}
	    } else {
		mk::set $cur size [mk::get $cur -size contents]
	    }
	    # added 30-10-2000
	    set db [lindex [split $cur .] 0]
	    mk::file autocommit $db
	} else {
	    # This should only be called for write operations...
	    error "Shouldn't call me for read ops"
	}
    } err]} {
	global errorInfo
	tclLog "mk4vfs::do_close callback error: $err $errorInfo"
    }
}

proc mk4vfs::mkdir {db path} {
    set sp [::file split $path]
    set parent 0
    set view $db.dirs

    set npath {}
    foreach ele $sp {
        set npath [file join $npath $ele]

        if { ![catch {stat $db $npath sb}] } {
            if { $sb(type) != "directory" } {
                return -code error "can't create directory \"$npath\": file already exists"
            }
            set parent [mk::cursor position sb(ino)]
            continue
        }
        #set parent [mk::cursor position sb(ino)]
#puts "set cur \[mk::row append $view name $ele parent $parent]"
        set cur [mk::row append $view name $ele parent $parent]
        set parent [mk::cursor position cur]
    }
}

# removed this from 'getdir' proc.
if { 0 } {
    foreach row [mk::select $sb(view) parent $parent -glob name $pat] {
	if { $row == 0 } {continue}

	set hits([mk::get $sb(view)!$row name]) 1
    }
    # Match files
    set view $sb(view)!$parent.files
    foreach row [mk::select $view -glob name $pat] {
	set hits([mk::get $view!$row name]) 1
    }
} 

proc mk4vfs::getdir {db path {pat *}} {
    #tclLog [list mk4vfs::getdir $db $path $pat]

    if { [catch {
        stat $db $path sb
    }] } {
        return {}
    }

    if { $sb(type) != "directory" } {
        return {}
        #return -code error "bad path \"$path\": not a directory"
    }
    # Match directories
    set parent [mk::cursor position sb(ino)] 
    mk::loop sb(ino) {
	if { [mk::get $sb(ino) parent] == $parent &&
	     [string match $pat [mk::get $sb(ino) name]] &&
	     [mk::cursor position sb(ino)] != 0 } {
	    set hits([mk::get $sb(ino) name]) 1
	}
    }
    # Match files
    mk::loop sb(ino) $sb(view)!$parent.files {
	if { [string match $pat [mk::get $sb(ino) name]] } {
	    set hits([mk::get $sb(ino) name]) 1
	}
    }
    return [lsort [array names hits]]
}

proc mk4vfs::mtime {db path time} {

    stat $db $path sb

    if { $sb(type) == "file" } {
        mk::set $sb(ino) date $time
    }
    return $time
}

proc mk4vfs::delete {db path {recursive 0}} {
    #tclLog "trying to delete $path"
    set rc [catch { stat $db $path sb } err]
    if { $rc }  {
	#tclLog "delete error: $err"
	return -code error $err
    }
    if {$sb(type) == "file" } {
	mk::row delete $sb(ino)
    } else {
	# just mark dirs as deleted
	set contents [getdir $db $path *]
	#puts "path, $contents"
	if {$recursive} {
	    # We have to delete these manually, else
	    # they (or their cache) may conflict with
	    # something later
	    foreach f $contents {
		delete $db [file join $path $f] $recursive
	    }
	} else {
	    if {[llength $contents]} {
		return -code error "Non-empty"
	    }
	}
	set tail [file tail $path]
	variable cache
	set var2 "$sb(view)![mk::get $sb(ino) parent],$tail"
	#puts "del $path, $tail , $var2, [info exists cache($var2)]"
	if {[info exists cache($var2)]} {
	    #puts "remove2: $path $var2 $cache($var2)"
	    unset cache($var2)
	}
	
	mk::set $sb(ino) parent -1
    }
    return ""
}

proc mk4vfs::find/file {v name} {
    mk::loop cur $v {
	if { [string equal [mk::get $cur name] $name] } {
	    return [mk::cursor position cur]
	}
    }
    return -1
}

proc mk4vfs::find/dir {v name parent} {
    mk::loop cur $v {
	if {	[mk::get $cur parent] == $parent &&
		[string equal [mk::get $cur name] $name] } {
	    return [mk::cursor position cur]
	}
    }
    return -1
}
