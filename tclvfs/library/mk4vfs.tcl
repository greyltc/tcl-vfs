# mk4vfs.tcl -- Mk4tcl Virtual File System driver
# Copyright (C) 1997-2001 Sensus Consulting Ltd. All Rights Reserved.
# Matt Newman <matt@sensus.org> and Jean-Claude Wippler <jcw@equi4.com>
#
# $Id$
#

# uses Pink for zip and md5 replacements, this avoids the dependency on Trf

  package ifneeded Trf 1.3 {
    package require pink
    package provide Trf 1.3
  
    proc zip {flag value data} {
      switch -glob -- "$flag $value" {
	{-mode d*} { set mode decompress }
	{-mode c*} { set mode compress }
	default    { error "usage: zip -mode {compress|decompress} data" }
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

# this replacement is for memchan, used for simple (de)compression

  package ifneeded Memchan 0.1 {
    package require rechan
    package provide Memchan 0.1
  
    proc _memchan_handler {cmd fd args} {
      upvar #0 ::_memchan_buf($fd) _buf
      upvar #0 ::_memchan_pos($fd) _pos
      set arg1 [lindex $args 0]
      
      switch -- $cmd {
	seek {
	  switch [lindex $args 1] {
	    1 - current { incr arg1 $_pos }
	    2 - end { incr arg1 [string length $_buf]}
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
    
namespace eval vfs::mk4 {}

proc vfs::mk4::Mount {what local args} {
  set db [eval [list ::mk4vfs::_mount $what $local] $args]
  ::vfs::filesystem mount $what [list ::vfs::mk4::handler $db]
  ::vfs::RegisterMount $local [list ::vfs::mk4::Unmount $db]
  return $db
}

proc vfs::mk4::Unmount {db local} {
  vfs::filesystem unmount $local
  ::mk4vfs::_umount $db
}

proc vfs::mk4::handler {db cmd root relative actualpath args} {
  if {$cmd == "matchindirectory"} {
    eval [list $cmd $db $relative $actualpath] $args
  } elseif {$cmd == "fileattributes"} {
    eval [list $cmd $db $root $relative] $args
  } else {
    eval [list $cmd $db $relative] $args
  }
}

proc vfs::mk4::utime {db path actime modtime} {
  ::mk4vfs::stat $db $path sb
  
  if { $sb(type) == "file" } {
    ::mk::set $sb(ino) date $modtime
  }
}

# If we implement the commands below, we will have a perfect
# virtual file system for zip files.

proc vfs::mk4::matchindirectory {db path actualpath pattern type} {
  set newres [list]
  if {![string length $pattern]} {
    # check single file
    set res [list $actualpath]
    set actualpath ""
  } else {
    set res [::mk4vfs::getdir $db $path $pattern]
  }
  foreach p [::vfs::matchCorrectTypes $type $res $actualpath] {
    lappend newres "$actualpath$p"
  }
  return $newres
}

proc vfs::mk4::stat {db name} {
  ::mk4vfs::stat $db $name sb

  set sb(ino) 0
  array get sb
}

proc vfs::mk4::access {db name mode} {
  # This needs implementing better.  
  ::mk4vfs::stat $db $name sb
}

proc vfs::mk4::open {db file mode permissions} {
  # return a list of two elements:
  # 1. first element is the Tcl channel name which has been opened
  # 2. second element (optional) is a command to evaluate when
  #  the channel is closed.
  switch -glob -- $mode {
    {}  -
    r {
      ::mk4vfs::stat $db $file sb
    
      if { $sb(csize) != $sb(size) } {
        package require Trf
        package require Memchan

        set fd [memchan]
        fconfigure $fd -translation binary
        set s [mk::get $sb(ino) contents]
        puts -nonewline $fd [zip -mode decompress $s]

        fconfigure $fd -translation auto
        seek $fd 0
        return [list $fd [list _memchan_handler close $fd]]
      } elseif { $::mk4vfs::direct } {
        package require Trf
        package require Memchan

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
    a {
      if { [catch {::mk4vfs::stat $db $file sb }] } {
        # Create file
        ::mk4vfs::stat $db [file dirname $file] sb
	set tail [file tail $file]
        set fview $sb(ino).files
        if {[info exists mk4vfs::v::fcache($fview)]} {
	  lappend mk4vfs::v::fcache($fview) $tail
        }
	set now [clock seconds]
        set sb(ino) [mk::row append $fview name $tail size 0 date $now ]

        if { [string match *z* $mode] || $mk4vfs::compress } {
          set sb(csize) -1  ;# HACK - force compression
        } else {
          set sb(csize) 0
        }
      }

      if { $sb(csize) != $sb(size) } {
        package require Trf
        package require Memchan

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
        # Create file
        ::mk4vfs::stat $db [file dirname $file] sb
	set tail [file tail $file]
        set fview $sb(ino).files
        if {[info exists mk4vfs::v::fcache($fview)]} {
	  lappend mk4vfs::v::fcache($fview) $tail
	}
	set now [clock seconds]
        set sb(ino) [mk::row append $fview name $tail size 0 date $now ]
      }

      if { [string match *z* $mode] || $mk4vfs::compress } {
        package require Trf
        package require Memchan
        append mode z
        set fd [memchan]
      } else {
        set fd [mk::channel $sb(ino) contents w]
      }
      return [list $fd [list mk4vfs::do_close $fd $mode $sb(ino)]]
    }
    default   {
      error "illegal access mode \"$mode\""
    }
  }
}

proc vfs::mk4::createdirectory {db name} {
  mk4vfs::mkdir $db $name
}

proc vfs::mk4::removedirectory {db name} {
  mk4vfs::delete $db $name
}

proc vfs::mk4::deletefile {db name} {
  mk4vfs::delete $db $name
}

proc vfs::mk4::fileattributes {db root relative args} {
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
  variable compress 1     ;# HACK - needs to be part of "Super-Block"
  variable flush    5000  ;# Auto-Commit frequency
  variable direct   0	  ;# read through a memchan, or from Mk4tcl if zero

  namespace eval v {
    variable seq      0

    array set cache {}
    array set fcache {}
  }

  namespace export mount umount
}

proc mk4vfs::init {db} {
  mk::view layout $db.dirs {name:S parent:I {files {name:S size:I date:I contents:M}}}

  if { [mk::view size $db.dirs] == 0 } {
    mk::row append $db.dirs name <root> parent 0
  }

  # 2001-12-13: use parent -1 for root level!
  mk::set $db.dirs!0 parent -1
}

proc mk4vfs::mount {args} {
  uplevel ::vfs::mk4::Mount $args
}

proc mk4vfs::_mount {path file args} {
  set db mk4vfs[incr v::seq]

  eval [list mk::file open $db $file] $args

  init $db

  set flush 1
  for {set idx 0} {$idx < [llength $args]} {incr idx} {
    switch -- [lindex $args $idx] {
      -readonly   -
      -nocommit   {set flush 0}
    }
  }
  if { $flush } {
    _commit $db
  }
  return $db
}

proc mk4vfs::_commit {db} {
  variable flush
  after $flush [list mk4vfs::_commit $db]
  mk::file commit $db
}

proc mk4vfs::umount {local} {
  foreach {db path} [mk::file open] {
    if {[string equal $local $path]} {
      uplevel ::vfs::mk4::Unmount $db $local
      return
    }
  }
  tclLog "umount $local? [mk::file open]"
}

proc mk4vfs::_umount {db} {
  after cancel [list mk4vfs::_commit $db]
  array unset v::cache $db,*
  array unset v::fcache $db.*
  mk::file close $db
}

proc mk4vfs::stat {db path arr} {
  upvar 1 $arr sb

  set sp [::file split $path]
  set tail [lindex $sp end]

  set parent 0
  set view $db.dirs
  set type directory

  foreach ele [lrange $sp 0 end-1] {
    if {[info exists v::cache($db,$parent,$ele)]} {
      set parent $v::cache($db,$parent,$ele)
    } else {
      set row [mk::select $view -count 1 parent $parent name $ele]
      if { $row == "" } {
        return -code error "could not read \"$path\": no such file or directory"
      }
      set v::cache($db,$parent,$ele) $row
      set parent $row
    }
  }
  
  # Now check if final comp is a directory or a file
  # CACHING is required - it can deliver a x15 speed-up!
  
  if { [string equal $tail "."] || [string equal $tail ":"] ||
  				  	[string equal $tail ""] } {
    set row $parent

  } elseif { [info exists v::cache($db,$parent,$tail)] } {
    set row $v::cache($db,$parent,$tail)
  } else {
    # File?
    set fview $view!$parent.files
    # create a name cache of files in this directory
    if {![info exists v::fcache($fview)]} {
      # cache only a limited number of directories
      if {[array size v::fcache] >= 10} {
        array unset v::fcache *
      }
      set v::fcache($fview) {}
      mk::loop c $fview {
        lappend v::fcache($fview) [mk::get $c name]
      }
    }
    set row [lsearch -exact $v::fcache($fview) $tail]
    #set row [mk::select $fview -count 1 name $tail]
    #if {$row == ""} { set row -1 }
    if { $row != -1 } {
      set type file
      set view $view!$parent.files
    } else {
      # Directory?
      set row [mk::select $view -count 1 parent $parent name $tail]
      if { $row != "" } {
        set v::cache($db,$parent,$tail) $row
      } else { 
        return -code error "could not read \"$path\": no such file or directory"
      }
    }
  }
  set cur $view!$row

  set sb(type)    $type
  set sb(view)    $view
  set sb(ino)     $cur

  if { [string equal $type "directory"] } {
    set sb(atime) 0
    set sb(ctime) 0
    set sb(gid)   0
    set sb(mode)  0777
    set sb(mtime) 0
    set sb(nlink) [expr { [mk::get $cur files] + 1 }]
    set sb(size)  0
    set sb(csize) 0
    set sb(uid)   0
  } else {
    set mtime   [mk::get $cur date]
    set sb(atime) $mtime
    set sb(ctime) $mtime
    set sb(gid)   0
    set sb(mode)  0777
    set sb(mtime) $mtime
    set sb(nlink) 1
    set sb(size)  [mk::get $cur size]
    set sb(csize) [mk::get $cur -size contents]
    set sb(uid)   0
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
        # this was a duplicate close!!! 12-10-2001
        #close $fd
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
###!!!  return -code error $err
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
    set cur [mk::row append $view name $ele parent $parent]
    set parent [mk::cursor position cur]
  }
}

proc mk4vfs::getdir {db path {pat *}} {
  if {[catch { stat $db $path sb }] || $sb(type) != "directory" } {
    return
  }

  # Match directories
  set parent [mk::cursor position sb(ino)] 
  foreach row [mk::select $sb(view) parent $parent -glob name $pat] {
    set hits([mk::get $sb(view)!$row name]) 1
  }
  # Match files
  set view $sb(view)!$parent.files
  foreach row [mk::select $view -glob name $pat] {
    set hits([mk::get $view!$row name]) 1
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
  stat $db $path sb
  if {$sb(type) == "file" } {
    mk::row delete $sb(ino)
    if {[regexp {(.*)!(\d+)} $sb(ino) - v r] && [info exists v::fcache($v)]} {
      set v::fcache($v) [lreplace $v::fcache($v) $r $r]
    }
  } else {
    # just mark dirs as deleted
    set contents [getdir $db $path *]
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
    array unset v::cache "$db,[mk::get $sb(ino) parent],[file tail $path]"
    
    mk::set $sb(ino) parent -1 name ""
  }
  return ""
}
