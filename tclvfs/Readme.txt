Hello!  The code here has evolved from ideas and excellent work by Matt
Newman, Jean-Claude Wippler, TclKit etc.  To make this really successful,
we need a group of volunteers to enhance what we have and build a new way
of writing and distributing Tcl code.

Introduction
------------

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

Current implementation
----------------------

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

Limitations
-----------

We can't currently mount a file protocol.  For example it would be nice to 
tell Tcl that we understand 'ftp://' as meaning an absolute path to be
handled by our ftp-vfs system.  Then we could so something like

    file copy ftp://ftp.foo.com/pub/readme.txt ~/readme.txt

and our ftp-vfs system can deal with it.  This is really a limitation in
Tcl's current understanding of file paths (and not any problem in this
extension per se).

Of course what we can do is mount any specific ftp address to somewhere in 
the filesystem.  For example, we can mount 'ftp://ftp.foo.com/ to
/ftp.foo.com/ and proceed from there.
    
Future thoughts
---------------

See:

http://www.ximian.com/tech/gnome-vfs.php3
http://www.lh.com/~oleg/ftp/HTTP-VFS.html

for some ideas.  It would be good to accumulate ideas on the limitations of
the current VFS support so we can plan out what vfs 2.0 will look like (and
what changes will be needed in Tcl's core to support it).  Obvious things
which come to mind are asynchronicity: 'file copy' from a mounted remote
site (ftp or http) is going to be very slow and simply block the
application.  Commands like that should have new asynchronous versions which
can be used when desired (e.g. 'file copy from to -callback foo').

