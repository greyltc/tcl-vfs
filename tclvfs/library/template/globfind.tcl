package provide globfind 1.0

namespace eval ::globfind {

proc globfind {{basedir .} {filtercmd {}}} {
	set depth 16
	set filt [string length $filtercmd]
	set basedir [file normalize $basedir]
	file stat $basedir fs
	set linkName $basedir
	while {$fs(type) == "link"} {
		if [catch {file stat [set linkName [file normalize [file link $linkName]]] fs}] {break}
	}
	if {$fs(type) == "file"} {
		set filename $basedir
		if {!$filt || [uplevel $filtercmd [list $filename]]} {
		            return [list $filename]
		}
	}
	set globPatternTotal {}
	set globPattern *
	set incrPattern /*
	for {set i 0} {$i < $depth} {incr i} {
		lappend globPatternTotal $globPattern
		append globPattern $incrPattern
	}

	lappend checkDirs $basedir
	set returnFiles {}
	set redo 0
	set terminate 0
	set hidden {}
	while {!$terminate} {
		set currentDir [lindex $checkDirs 0]
		if !$redo {set allFiles [eval glob -directory [list $currentDir] -nocomplain $hidden $globPatternTotal]}
		set redo 0
		set termFile [lindex $allFiles end]
		set termFile [lrange [file split $termFile] [llength [file split $currentDir]] end]
		if {$hidden != {}} {
			set checkDirs [lrange $checkDirs 1 end]
		}
		foreach test {checkdirs length duplicate recursion prune} {
			switch $test {
				checkdirs {
					set afIndex [llength $allFiles]
					incr afIndex -1
					for {set i $afIndex} {$i >= 0} {incr i -1} {
						set cdir [lindex $allFiles $i]
						if {[llength [lrange [file split $cdir] [llength [file split $currentDir]] end]] < $depth} {break}
						file stat $cdir fs
						set linkName $cdir
						while {$fs(type) == "link"} {
							if [catch {file stat [set linkName [file normalize [file link $linkName]]] fs}] {break}
						}
						if {$fs(type) == "directory"} {lappend checkDirs $cdir}
					}
				}					
				length {
					if {[llength $termFile] < $depth} {break}
				}
				duplicate {
					set recurseTest 0
					set dupFile [lindex $allFiles end]
					set dupFile [lrange [file split $dupFile] [llength [file split $basedir]] end]
					set dupFileEndDir [expr [llength $dupFile] - 2]
		                	if {[lsearch $dupFile [lindex $dupFile end-1]] < $dupFileEndDir} {
		                  	set recurseTest 1
					}
				}
				recursion {
					if !$recurseTest {continue}
					if {($hidden == {})} {set type "-types l"} else {set type "-types [list "hidden l"]"}

					set linkFiles {}
					set linkDir $currentDir
					while 1 {
						set linkFiles [concat $linkFiles [eval glob -directory [list $linkDir] -nocomplain $type $globPatternTotal]]
						if {$linkDir == $basedir} {break}
						set linkDir [file dirname $linkDir]
					}
					array unset links
					set linkFiles [lsort -unique $linkFiles]
					foreach lf $linkFiles {
						set ltarget [file normalize [file readlink $lf]]
						if {[array names links -exact $ltarget] != {}} {
							lappend pruneLinks $lf
							set redo 1
						}
						array set links "$ltarget $lf"
					}
				}
				prune {
					if ![info exists pruneLinks] {continue}
					set afIndex [llength $allFiles]
					incr afIndex -1
					set cdIndex [llength $checkDirs]
					incr cdIndex -1
					set rfIndex [llength $returnFiles]
					incr rfIndex -1
					foreach pl $pruneLinks {
						for {set i $afIndex} {$i >= 0} {incr i -1} {
							set af [lindex $allFiles $i]
							if ![string first $pl/ $af] {set allFiles [lreplace $allFiles $i $i]}
						}
						for {set i $cdIndex} {$i >= 0} {incr i -1} {
							set cd [lindex $checkDirs $i]
							if ![string first $pl/ $cd] {set checkDirs [lreplace $checkDirs $i $i]}
						}
						for {set i $rfIndex} {$i >= 0} {incr i -1} {
							set rf [lindex $returnFiles $i]
							if ![string first $pl/ $rf] {set returnFiles [lreplace $returnFiles $i $i]}
						}
					}
					unset pruneLinks
				}
				default {}
			}
		}
		if $redo continue
		if {$hidden == {}} {
			set hidden "-types hidden"
		} else {
			set hidden {}
			if {[llength $checkDirs] == 0} {set terminate 1}
		}
		set returnFiles [concat $returnFiles $allFiles]
	}
	set filterFiles {}
	foreach filename [lsort -unique [linsert $returnFiles end $basedir]] {
		if {!$filt || [uplevel $filtercmd [list $filename]]} {
			lappend filterFiles $filename
		}
	}
	return $filterFiles
}


proc scfind {args} {
	set filename [file join [pwd] [lindex $args end]]
	set switches [lrange $args 0 end-1]

	array set types {
		f	file
		d	directory
		c	characterSpecial
		b	blockSpecial
		p	fifo
		l	link
		s	socket
	}

	array set signs {
		- <
		+ >
	}

	array set multiplier {
		time 86400
		min   3600
	}
	file stat $filename fs
	set pass 1
	set switchLength [llength $switches]
	for {set i 0} {$i < $switchLength} {incr i} {
		set sw [lindex $switches $i]
		switch -- $sw {
			-type {
				set value [lindex $switches [incr i]]
				if ![string equal $fs(type) $types($value)] {return 0}
			}
			-regex {
				set value [lindex $switches [incr i]]
				if ![regexp $value $filename] {return 0}
			}
			-size {
				set value [lindex $switches [incr i]]
				set sign "=="
				if [info exists signs([string index $value 0])] {
					set sign $signs([string index $value 0])
					set value [string range $value 1 end]
				}
				set sizetype [string index $value end]
				set value [string range $value 0 end-1]
				if [string equal $sizetype b] {set value [expr $value * 512]}
				if [string equal $sizetype k] {set value [expr $value * 1024]}
				if [string equal $sizetype w] {set value [expr $value * 2]}

				if ![expr $fs(size) $sign $value] {return 0}
			}
			-atime -
			-mtime -
			-ctime -
			-amin -
			-mmin -
			-cmin {
				set value [lindex $switches [incr i]]

				set sw [string range $sw 1 end]
				set time [string index $sw 0]
				set interval [string range $sw 1 end]
				set sign "=="
				if [info exists signs([string index $value 0])] {
					set sign $signs([string index $value 0])
					set value [string range $value 1 end]
				}
				set value [expr [clock seconds] - ($value * $multiplier($interval))]
				if ![expr $value $sign $fs($sw)] {return 0}
			}
 		}
	}
	return 1
}

proc find {args} {
	globfind [lindex $args 0] [list [subst "scfind $args"]]
}

namespace export -clear globfind

}
# end namespace globfind



