

namespace eval ::vfs::url {}

proc vfs::url::Mount {type} {
    # This requires Tcl 8.4a4.
    set volume "${type}://"
    if {$type == "file"} {
	append volume "/"
    }
    ::vfs::addVolume $volume
    ::vfs::filesystem mount $volume [list vfs::url::handler $type]
}

proc vfs::url::handler {type cmd root relative actualpath args} {
    puts stderr [list $type $cmd $root $relative $actualpath $args]
    error ""
}

proc vfs::url::handler {args} {
    puts stderr $args
    error ""
}

