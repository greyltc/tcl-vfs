# Remnants of what used to be VFS init, this is TclKit-specific

package provide vfslib 1.3

namespace eval ::vfs {

# for backwards compatibility
  proc normalize {path} { ::file normalize $path }

# use zlib to define zip and crc if available
  if {[info command zlib] != "" || ![catch {load "" zlib}]} {

    proc zip {flag value args} {
      switch -glob -- "$flag $value" {
	{-mode d*} { set mode decompress }
	{-mode c*} { set mode compress }
	default { error "usage: zip -mode {compress|decompress} data" }
      }
      # kludge to allow "-nowrap 1" as second option, 5-9-2002
      if {[llength $args] > 2 && [lrange $args 0 1] == "-nowrap 1"} {
        if {$mode == "compress"} {
	  set mode deflate
	} else {
	  set mode inflate
	}
      }
      return [zlib $mode [lindex $args end]]
    }

    proc crc {data} {
      return [zlib crc32 $data]
    }
  }

# use rechan to define memchan if available
  if {[info command rechan] != "" || ![catch {load "" rechan}]} {

    proc memchan_handler {cmd fd args} {
      upvar ::vfs::_memchan_buf($fd) buf
      upvar ::vfs::_memchan_pos($fd) pos
      set arg1 [lindex $args 0]
      
      switch -- $cmd {
	seek {
	  switch [lindex $args 1] {
	    1 - current { incr arg1 $pos }
	    2 - end { incr arg1 [string length $buf]}
	  }
	  return [set pos $arg1]
	}
	read {
	  set r [string range $buf $pos [expr { $pos + $arg1 - 1 }]]
	  incr pos [string length $r]
	  return $r
	}
	write {
	  set n [string length $arg1]
	  if { $pos >= [string length $buf] } {
	    append buf $arg1
	  } else { # the following doesn't work yet :(
	    set last [expr { $pos + $n - 1 }]
	    set buf [string replace $buf $pos $last $arg1]
	    error "vfs memchan: sorry no inline write yet"
	  }
	  incr pos $n
	  return $n
	}
	close {
	  unset buf pos
	}
	default { error "bad cmd in memchan_handler: $cmd" }
      }
    }
  
    proc memchan {} {
      set fd [rechan ::vfs::memchan_handler 6]
      set ::vfs::_memchan_buf($fd) ""
      set ::vfs::_memchan_pos($fd) 0
      return $fd
    }
  }
}
