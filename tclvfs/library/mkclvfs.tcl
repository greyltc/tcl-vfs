# mkclvfs.tcl -- Metakit Compatible Lite Virtual File System driver
# Rewritten from mk4vfs.tcl, orig by by Matt Newman and Jean-Claude Wippler 
# $Id$

# 1.0	initial release
# 1.1	view size renamed to count, vlerq package renamed to thrill

package provide vfs::mkcl 1.1
package require vfs
package require thrill

namespace eval vfs::mkcl {
  namespace import ::thrill::*

  namespace eval v {
    variable seq 0  ;# used to generate a unique db handle
    variable rootv  ;# maps handle to root view (well, actually "dirs")
    variable dname  ;# maps handle to cached list of directory names
    variable prows  ;# maps handle to cached list of parent row numbers
  }

# public
  proc Mount {mkfile local args} {
    set db mkclvfs[incr v::seq]
    set v::rootv($db) [view [vopen $mkfile] get 0 dirs]
    set v::dname($db) [view $v::rootv($db) getcol 0]
    set v::prows($db) [view $v::rootv($db) getcol 1]
    ::vfs::filesystem mount $local [list ::vfs::mkcl::handler $db]
    ::vfs::RegisterMount $local [list ::vfs::mkcl::Unmount $db]
    return $db
  }
  proc Unmount {db local} {
    ::vfs::filesystem unmount $local
    unset v::rootv($db) v::dname($db) v::prows($db)
  }
# private
  proc handler {db cmd root path actual args} {
    #puts [list MKCL $db <$cmd> r: $root p: $path a: $actual $args]
    switch $cmd {
      matchindirectory	{ eval [linsert $args 0 $cmd $db $path $actual] }
      fileattributes	{ eval [linsert $args 0 $cmd $db $root $path] } 
      default		{ eval [linsert $args 0 $cmd $db $path] }
    }
  }
  proc fail {code} {
    ::vfs::filesystem posixerror $::vfs::posix($code)
  }
  proc lookUp {db path} {
    set dirs $v::rootv($db)
    set parent 0
    set elems [file split $path]
    set remain [llength $elems]
    foreach e $elems {
      set r ""
      foreach r [lsearch -exact -int -all $v::prows($db) $parent] {
	if {$e eq [lindex $v::dname($db) $r]} {
	  set parent $r
	  incr remain -1
	  break
	}
      }
      if {$parent != $r} {
	if {$remain == 1} {
	  set files [view $dirs get $parent 2]
	  set i [lsearch -exact [view $files getcol 0] $e]
	  if {$i >= 0} {
	    # evaluating this 4-item result returns the info about one file
	    return [list view $files get $i]
	  }
	}
	fail ENOENT
      }
    }
    # evaluating this 5-item result returns the files subview
    return [list view $dirs get $parent 2]
  }
  proc isDir {tag} {
    return [expr {[llength $tag] == 5}]
  }
# methods
  proc matchindirectory {db path actual pattern type} {
    set o {}
    if {$type == 0} { set type 20 }
    set tag [lookUp $db $path]
    if {$pattern ne ""} {
      set c {}
      if {[isDir $tag]} {
	# collect file names
	if {$type & 16} {
	  set c [eval [linsert $tag end | getcol 0]]
	}
	# collect directory names
	if {$type & 4} {
	  foreach r [lsearch -exact -int -all $v::prows($db) [lindex $tag 3]] {
	    lappend c [lindex $v::dname($db) $r]
	  }
	}
      }
      foreach x $c {
	if {[string match $pattern $x]} {
	  lappend o [file join $actual $x]
	}
      }
    } elseif {$type & ([isDir $tag]?4:16)} {
      set o [list $actual]
    }
    return $o
  }
  proc fileattributes {db root path args} {
    switch -- [llength $args] {
      0 { return [::vfs::listAttributes] }
      1 { set index [lindex $args 0]
	  return [::vfs::attributesGet $root $path $index] }
      2 { fail EROFS }
    }
  }
  proc open {db file mode permissions} {
    if {$mode ne "" && $mode ne "r"} { fail EROFS }
    set tag [lookUp $db $file]
    if {[isDir $tag]} { fail ENOENT }
    foreach {name size date contents} [eval $tag] break
    if {[string length $contents] != $size} {
      set contents [vfs::zip -mode decompress $contents]
    }
    set fd [vfs::memchan]
    fconfigure $fd -translation binary
    puts -nonewline $fd $contents
    fconfigure $fd -translation auto
    seek $fd 0
    return [list $fd]
  }
  proc access {db path mode} {
    if {$mode & 2} { fail EROFS }
    lookUp $db $path
  }
  proc stat {db path} {
    set tag [lookUp $db $path]
    set l 1
    if {[isDir $tag]} {
      set t directory
      set s 0
      set d 0
      set c ""
      incr l [eval [linsert $tag end | count]]
      incr l [llength [lsearch -exact -int -all $v::prows($db) [lindex $tag 3]]]
    } else {
      set t file
      foreach {n s d c} [eval $tag] break
    }
    return [list type $t size $s atime $d ctime $d mtime $d nlink $l \
		  csize [string length $c] gid 0 uid 0 ino 0 mode 0777]
  }
}
