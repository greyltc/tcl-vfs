This is an implementation of a 'vfs' extension (and a 'vfs' package,
including a small library of Tcl code).  The goal of this extension
is to expose Tcl 8.4a3's new filesystem C API to the Tcl level.

Since 8.4 is still in alpha, the APIs on which this extension depends may of
course change (although this isn't too likely).  If that happens, it will of
course require changes to this extension, until the point at which 8.4 goes
final, when only backwards-compatible changes should occur.

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

None of the vfs's included are 100% complete or optimal yet, so if only for
that reason, code contributions are very welcome.  Many of them still
contain various debugging code, etc.  This will be gradually removed and
the code completely cleaned up and documented as the package evolves.

-- Vince Darley, August 1st 2001

Some of the provided vfs's require the Memchan extension for any operation 
which involves opening files.

The vfs's currently available are:

--------+-----------------------------------------------------------------
vfs     |  mount command                       
--------+-----------------------------------------------------------------
zip     |  vfs::zip::Mount my.zip local
ftp     |  vfs::ftp::Mount ftp://user:pass@ftp.foo.com/dir/name/ local
mk4     |  vfs::mk4::Mount myMk4database local
test    |  vfs::test::Mount ...
tclproc |  vfs::tclproc::Mount ::tcl local
--------+-----------------------------------------------------------------

For file-systems which make use of a local file (e.g. mounting zip or mk4
archives), it is often most simple to have 'local' be the same name as 
the archive itself.  The result of this is that Tcl will then see the
archive as a directory, rather than a file.  Otherwise you might wish
to create a dummy file/directory called 'local' before mounting.

