
package require vfs 1.0

# Using the vfs, memchan and Trf extensions, we ought to be able
# to write a Tcl-only zip virtual filesystem.

namespace eval vfs::zip {}

proc vfs::zip::Mount {zipfile local} {
    set fd [::zip::open [::file normalize $zipfile]]
    vfs::filesystem mount $local [list vfs::zip::handler $fd]
    return $fd
}

proc vfs::zip::Unmount {fd} {
    ::zip::_close $fd
}

proc vfs::zip::handler {zipfd cmd root relative actualpath args} {
    #puts [list $zipfd $cmd $root $relative $actualpath $args]
    #update
    if {$cmd == "matchindirectory"} {
	eval [list $cmd $zipfd $relative $actualpath] $args
    } else {
	eval [list $cmd $zipfd $relative] $args
    }
}

# If we implement the commands below, we will have a perfect
# virtual file system for zip files.

proc vfs::zip::matchindirectory {zipfd path actualpath pattern type} {
    #puts stderr [list matchindirectory $path $actualpath $pattern $type]
    set res [::zip::getdir $zipfd $path $pattern]
    #puts stderr "got $res"
    set newres [list]
    foreach p [::vfs::matchCorrectTypes $type $res $actualpath] {
	lappend newres "$actualpath$p"
    }
    #puts "got $newres"
    return $newres
}

proc vfs::zip::stat {zipfd name} {
    #puts "stat $name"
    ::zip::stat $zipfd $name sb
    #puts [array get sb]
    array get sb
}

proc vfs::zip::access {zipfd name mode} {
    #puts "zip-access $name $mode"
    if {$mode & 2} {
	error "read-only"
    }
    # Readable, Exists and Executable are treated as 'exists'
    # Could we get more information from the archive?
    if {[::zip::exists $zipfd $name]} {
	return 1
    } else {
	error "No such file"
    }
    
}

proc vfs::zip::open {zipfd name mode permissions} {
    #puts "open $name $mode $permissions"
    # return a list of two elements:
    # 1. first element is the Tcl channel name which has been opened
    # 2. second element (optional) is a command to evaluate when
    #    the channel is closed.

    switch -- $mode {
	"" -
	"r" {
	    if {![::zip::exists $zipfd $name]} {
		return -code error $::vfs::posix(ENOENT)
	    }
	    
	    ::zip::stat $zipfd $name sb

	    package require Trf
	    package require Memchan

	    set nfd [memchan]
	    fconfigure $nfd -translation binary

	    seek $zipfd $sb(ino) start
	    zip::Data $zipfd sb data

	    puts -nonewline $nfd $data

	    fconfigure $nfd -translation auto
	    seek $nfd 0
	    return [list $nfd]
	}
	default {
	    return -code error "illegal access mode \"$mode\""
	}
    }
}

proc vfs::zip::createdirectory {zipfd name} {
    #puts stderr "createdirectory $name"
    error "read-only"
}

proc vfs::zip::removedirectory {zipfd name} {
    #puts stderr "removedirectory $name"
    error "read-only"
}

proc vfs::zip::deletefile {zipfd name} {
    #puts "deletefile $name"
    error "read-only"
}

proc vfs::zip::fileattributes {zipfd name args} {
    #puts "fileattributes $args"
    switch -- [llength $args] {
	0 {
	    # list strings
	    return [list]
	}
	1 {
	    # get value
	    set index [lindex $args 0]
	    return ""
	}
	2 {
	    # set value
	    set index [lindex $args 0]
	    set val [lindex $args 1]
	    error "read-only"
	}
    }
}

# Below copied from TclKit distribution

#
# ZIP decoder:
#
# Format of zip file:
# [ Data ]* [ TOC ]* EndOfArchive
#
# Note: TOC is refered to in ZIP doc as "Central Archive"
#
# This means there are two ways of accessing:
#
# 1) from the begining as a stream - until the header
#	is not "PK\03\04" - ideal for unzipping.
#
# 2) for table of contents without reading entire
#	archive by first fetching EndOfArchive, then
#	just loading the TOC
#
package provide vfs.zip 0.5

namespace eval zip {
    array set methods {
	0	{stored - The file is stored (no compression)}
	1	{shrunk - The file is Shrunk}
	2	{reduce1 - The file is Reduced with compression factor 1}
	3	{reduce2 - The file is Reduced with compression factor 2}
	4	{reduce3 - The file is Reduced with compression factor 3}
	5	{reduce4 - The file is Reduced with compression factor 4}
	6	{implode - The file is Imploded}
	7	{reserved - Reserved for Tokenizing compression algorithm}
	8	{deflate - The file is Deflated}
	9	{reserved - Reserved for enhanced Deflating}
	10	{pkimplode - PKWARE Date Compression Library Imploding}
    }
    # Version types (high-order byte)
    array set systems {
	0	{dos}
	1	{amiga}
	2	{vms}
	3	{unix}
	4	{vm cms}
	5	{atari}
	6	{os/2}
	7	{macos}
	8	{z system 8}
	9	{cp/m}
	10	{tops20}
	11	{windows}
	12	{qdos}
	13	{riscos}
	14	{vfat}
	15	{mvs}
	16	{beos}
	17	{tandem}
	18	{theos}
    }
    # DOS File Attrs
    array set dosattrs {
	1	{readonly}
	2	{hidden}
	4	{system}
	8	{unknown8}
	16	{directory}
	32	{archive}
	64	{unknown64}
	128	{normal}
    }

    proc u_short {n}  { return [expr { ($n+0x10000)%0x10000 }] }
}

proc zip::DosTime {date time} {
    set time [u_short $time]
    set date [u_short $date]

    set sec [expr { ($time & 0x1F) * 2 }]
    set min [expr { ($time >> 5) & 0x3F }]
    set hour [expr { ($time >> 11) & 0x1F }]

    set mday [expr { $date & 0x1F }]
    set mon [expr { (($date >> 5) & 0xF) }]
    set year [expr { (($date >> 9) & 0xFF) + 1980 }]

    set dt [format {%4.4d-%2.2d-%2.2d %2.2d:%2.2d:%2.2d} \
	$year $mon $mday $hour $min $sec]
    return [clock scan $dt -gmt 1]
}


proc zip::Data {fd arr {varPtr ""} {verify 0}} {
    upvar 1 $arr sb

    if { $varPtr != "" } {
	upvar 1 $varPtr data
    }

    set buf [read $fd 30]
    set n [binary scan $buf A4sssssiiiss \
		hdr sb(ver) sb(flags) sb(method) \
		time date \
		sb(crc) sb(csize) sb(size) flen elen]

    if { ![string equal "PK\03\04" $hdr] } {
	error "bad header: [hexdump $hdr]"
    }
    set sb(ver)		[u_short $sb(ver)]
    set sb(flags)	[u_short $sb(flags)]
    set sb(method)	[u_short $sb(method)]
    set sb(mtime)	[DosTime $date $time]

    set sb(name) [read $fd [u_short $flen]]
    set sb(extra) [read $fd [u_short $elen]]

    if { $varPtr == "" } {
	seek $fd $sb(csize) current
    } else {
	set data [read $fd $sb(csize)]
    }

    if { $sb(flags) & 0x4 } {
	# Data Descriptor used
	set buf [read $fd 12]
	binary scan $buf iii sb(crc) sb(csize) sb(size)
    }


    if { $varPtr == "" } {
	return ""
    }

    if { $sb(method) != 0 } {
	if { [catch {
	    set data [zip -mode decompress -nowrap 1 $data]
	} err] } {
	    puts "$sb(name): inflate error: $err"
	    puts [hexdump $data]
	}
    }
    return
    if { $verify } {
	set ncrc [pink zlib crc $data]
	if { $ncrc != $sb(crc) } {
	    tclLog [format {%s: crc mismatch: expected 0x%x, got 0x%x} \
		    $sb(name) $sb(crc) $ncrc]
	}
    }
}

proc zip::EndOfArchive {fd arr} {
    upvar 1 $arr cb

    seek $fd -22 end
    set pos [tell $fd]
    set hdr [read $fd 22]

    binary scan $hdr A4ssssiis xhdr \
	cb(ndisk) cb(cdisk) \
	cb(nitems) cb(ntotal) \
	cb(csize) cb(coff) \
	cb(comment) 

    if { ![string equal "PK\05\06" $xhdr]} {
	error "bad header"
    }

    set cb(ndisk)	[u_short $cb(ndisk)]
    set cb(nitems)	[u_short $cb(nitems)]
    set cb(ntotal)	[u_short $cb(ntotal)]
    set cb(comment)	[u_short $cb(comment)]

    # Compute base for situations where ZIP file
    # has been appended to another media (e.g. EXE)
    set cb(base)	[expr { $pos - $cb(csize) - $cb(coff) }]
}

proc zip::TOC {fd arr} {
    upvar 1 $arr sb

    set buf [read $fd 46]

    binary scan $buf A4ssssssiiisssssii hdr \
	    sb(vem) sb(ver) sb(flags) sb(method) time date \
	    sb(crc) sb(csize) sb(size) \
	    flen elen clen sb(disk) sb(attr) \
	    sb(atx) sb(ino)

    if { ![string equal "PK\01\02" $hdr] } {
	error "bad central header: [hexdump $buf]"
    }

    foreach v {vem ver flags method disk attr} {
	set cb($v) [u_short [set sb($v)]]
    }

    set sb(mtime) [DosTime $date $time]
    set sb(mode) [expr { ($sb(atx) >> 16) & 0xffff }]
    if { ( $sb(atx) & 0xff ) & 16 } {
	set sb(type) directory
    } else {
	set sb(type) file
    }
    set sb(name) [read $fd [u_short $flen]]
    set sb(extra) [read $fd [u_short $elen]]
    set sb(comment) [read $fd [u_short $clen]]
}

proc zip::open {path} {
    set fd [::open $path]
    upvar #0 zip::$fd cb
    upvar #0 zip::$fd.toc toc

    fconfigure $fd -translation binary ;#-buffering none

    zip::EndOfArchive $fd cb

    seek $fd $cb(coff) start

    set toc(_) 0; unset toc(_); #MakeArray

    for { set i 0 } { $i < $cb(nitems) } { incr i } {
	zip::TOC $fd sb

	set sb(depth) [llength [file split $sb(name)]]

	set name [string tolower $sb(name)]
	set toc($name) [array get sb]
	FAKEDIR toc [file dirname $name]
    }

    return $fd
}

proc zip::FAKEDIR {arr path} {
    upvar 1 $arr toc

    if { $path == "."} { return }


    if { ![info exists toc($path)] } {
	# Implicit directory
	lappend toc($path) \
		name $path \
		type directory mtime 0 size 0 mode 0777 \
		ino -1 depth [llength [file split $path]]
    }
    FAKEDIR toc [file dirname $path]
}

proc zip::exists {fd path} {
    #puts stderr "$fd $path"
    if {$path == ""} {
	return 1
    } else {
	upvar #0 zip::$fd.toc toc
	info exists toc([string tolower $path])
    }
}

proc zip::stat {fd path arr} {
    upvar #0 zip::$fd.toc toc
    upvar 1 $arr sb

    set name [string tolower $path]
    if { $name == "" || $name == "." } {
	array set sb {
	    type directory mtime 0 size 0 mode 0777 
	    ino -1 depth 0 name ""
	}
    } elseif {![info exists toc($name)] } {
	return -code error "could not read \"$path\": no such file or directory"
    } else {
	array set sb $toc($name)
    }
    set sb(dev) -1
    set sb(uid)	-1
    set sb(gid)	-1
    set sb(nlink) 1
    set sb(atime) $sb(mtime)
    set sb(ctime) $sb(mtime)
    return ""
}

proc zip::getdir {fd path {pat *}} {
#    puts stderr [list getdir $fd $path $pat]
    upvar #0 zip::$fd.toc toc

    if { $path == "." || $path == "" } {
	set path $pat
    } else {
	set path [string tolower $path]
	append path /$pat
    }
    set depth [llength [file split $path]]

    set ret {}
    foreach key [array names toc $path] {
	if {[string index $key end] == "/"} {
	    # Directories are listed twice: both with and without
	    # the trailing '/', so we ignore the one with
	    continue
	}
	array set sb $toc($key)

	if { $sb(depth) == $depth } {
	    if {[info exists toc(${key}/)]} {
		array set sb $toc(${key}/)
	    }
	    lappend ret [file tail $sb(name)]
	} else {
	    #puts "$sb(depth) vs $depth for $sb(name)"
	}
	unset sb
    }
    return $ret
}

proc zip::_close {fd} {
    variable $fd
    variable $fd.toc
    unset $fd
    unset $fd.toc
}
#
#
return
#
# DEMO UNZIP -L PROGRAM
#
array set opts {
    -datefmt	{%m-%d-%y  %H:%M}
    -verbose	1
    -extract	0
    -debug	0
}
set file [lindex $argv 0]
array set opts [lrange $argv 1 end]

set fd [open $file]
fconfigure $fd -translation binary ;#-buffering none

if { !$opts(-extract) } {
    if { !$opts(-verbose) } {
	puts " Length    Date    Time    Name"
	puts " ------    ----    ----    ----"
    } else {
	puts " Length  Method   Size  Ratio   Date    Time   CRC-32     Name"
	puts " ------  ------   ----  -----   ----    ----   ------     ----"
    }
}

zip::EndOfArchive $fd cb

seek $fd $cb(coff) start

set TOC {}
for { set i 0 } { $i < $cb(nitems) } { incr i } {

    zip::TOC $fd sb

    lappend TOC $sb(name) $sb(ino)

    if { $opts(-extract) } {
	continue
    }

    if { !$opts(-verbose) } {
	puts [format {%7d  %-16s  %s} $sb(size) \
		[clock format $sb(mtime) -format $opts(-datefmt) -gmt 1] \
		$sb(name)]
    } else {
	if { $sb(size) > 0 } {
	    set cr [expr { 100 - 100 * $sb(csize) / double($sb(size)) }]
	} else {
	    set cr 0
	}
	puts [format {%7d  %6.6s %7d %3.0f%%  %s  %8.8x   %s} \
		$sb(size) [lindex $::zip::methods($sb(method)) 0] \
		$sb(csize) $cr \
		[clock format $sb(mtime) -format $opts(-datefmt) -gmt 1] \
		$sb(crc) $sb(name)]

	if { $opts(-debug) } {
	    set maj [expr { ($sb(vem) & 0xff)/10 }]
	    set min [expr { ($sb(vem) & 0xff)%10 }]
	    set sys [expr { $sb(vem) >> 8 }]
	    puts "made by version $maj.$min on system type $sys -> $::zip::systems($sys)"

	    set maj [expr { ($sb(ver) & 0xff)/10 }]
	    set min [expr { ($sb(ver) & 0xff)%10 }]
	    set sys [expr { $sb(ver) >> 8 }]
	    puts "need version $maj.$min on system type $sys -> $::zip::systems($sys)"

	    puts "file type is [expr { $sb(attr) == 1 ? "text" : "binary" }]"
	    puts "file mode is $sb(mode)"

	    set att [expr { $sb(atx) & 0xff }]
	    set flgs {}
	    foreach {k v} [array get ::zip::dosattrs] {
		if { $k & $att } {
		    lappend flgs $v
		}
	    }
	    puts "dos file attrs = [join $flgs]"
	}
    }
}
#
# This doesn't do anything right now except read each
# entry and inflate the data and double-check the crc
#

if { $opts(-extract) } {
    seek $fd $cb(base) start

    foreach {name idx} $TOC {
	#seek $fd $idx start

	zip::Data $fd sb data

	# The slowness of this code is actually Tcl's file i/o
	# I  suspect there are levels of buffer duplication
	# wasting cpu and memory cycles....
	file mkdir [file dirname $sb(name)]

	set nfd [open $sb(name) w]
	fconfigure $nfd -translation binary -buffering none
	puts -nonewline $nfd $data
	close $nfd

	puts "$sb(name): $sb(size) bytes"
    }
}
