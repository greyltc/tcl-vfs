#!/bin/sh
#-*-tcl-*-
# the next line restarts using wish \
exec tclsh "$0" ${1+"$@"}

catch {console show}

puts "(pwd is '[pwd]', file volumes is '[file volumes]')"

package require vfs

puts "Adding ftp:// volume..."
vfs::urltype::Mount ftp
set listing [glob -dir ftp://ftp.scriptics.com/pub *]
puts "ftp.scriptics.com/pub listing"
puts "$listing"
puts "----"
puts "(file volumes is '[file volumes]')"

puts "Adding http:// volume..."
vfs::urltype::Mount http
set fd [open http://sourceforge.net/projects/tcl]
set contents [read $fd] ; close $fd
puts "Contents of <http://sourceforge.net/projects/tcl> web page"
puts [string range $contents 0 100]
puts "(first 100 out of [string length $contents] characters)"
puts "----"
puts "(file volumes is '[file volumes]')"

puts "Mounting ftp://ftp.ucsd.edu/pub/alpha/ ..."
vfs::ftp::Mount ftp://ftp.ucsd.edu/pub/alpha/ localmount
cd localmount ; cd tcl
puts "(pwd is now '[pwd]')"
puts "sourcing remote file 'vfsTest.tcl', using 'source vfsTest.tcl'"
source vfsTest.tcl

puts "Done"
