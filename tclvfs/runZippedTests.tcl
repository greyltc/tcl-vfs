catch {
    wm withdraw .
    console show
}

catch {file delete tests.zip}

puts stdout "Zipping tests" ; update
exec zip -q -9 tests.zip tests/*
puts stdout "Done zipping"

cd [file dirname [info script]]

if {[catch {package require vfs}]} {
    cd win
    load vfs10d.dll
    cd ..
    lappend auto_path [file join [pwd] library]
}

lappend auto_path "C:/Program Files/Tcl/lib"
package require Trf
package require Memchan

set mount [vfs::zip::Mount tests.zip tests.zip]
puts "Zip mount is $mount"
update
if {[catch {
    cd tests.zip
    cd tests
    #source cmdAH.test
    source all.tcl
} err]} {
    puts stdout "Got error $err"
}
puts "Tests complete"
#vfs::zip::Unmount $mount

#exit
