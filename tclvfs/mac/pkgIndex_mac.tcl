# Tcl package index file, version 1.1

package ifneeded vfs 1.0 "load [list [file join $dir Vfs[info sharedlibextension]]] vfs
source -rsrc vfs:tclIndex"

package ifneeded scripdoc 0.3 [list source -rsrc scripdoc]
package ifneeded mk4vfs 1.0 [list source -rsrc mk4vfs]
package ifneeded vfslib 0.1 [list source -rsrc vfs]
