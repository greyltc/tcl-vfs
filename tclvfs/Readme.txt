This is an implementation of a 'vfs' extension (and a 'vfs' package,
including a small library of Tcl code).  The goal of this extension
is to expose Tcl 8.4a3's new filesystem C API to the Tcl level.

Since 8.4 is still in alpha, the APIs on which this extension depends may of
course change (although this isn't too likely).  If that happens, it will of
course require changes to this extension, until the point at which 8.4 goes
final, when only backwards-compatible changes should occur.

The 'zip' vfs package should work (more or less).  There is a framework for
a 'ftp' vfs package which needs filling in.

Using this extension, the editor Alphatk can actually auto-mount, view and
edit (but not save, since they're read-only) the contents of .zip files
directly (see <http://www.santafe.edu/~vince/Alphatk.html>).

The 'tests' directory contains a partially modified version of some of
Tcl's core tests.  They are modified in that there is a new 'fsIsWritable'
test constraint, which needs adding to several hundred tests (I've done
some of that work).

To install, you probably want to rename the directory 'library' to 'vfs1.0'
and place it in your Tcl hierarchy, with the necessary shared library
inside.

-- Vince Darley, August 1st 2001


