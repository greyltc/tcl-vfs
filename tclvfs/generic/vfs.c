/* 
 * vfs.c --
 *
 *	This file contains the implementation of the Vfs extension
 *	to Tcl.  It provides a script level interface to Tcl's 
 *	virtual file system support, and therefore allows 
 *	vfs's to be implemented in Tcl.
 *	
 *	The code is thread-safe.  Although under normal use only
 *	one interpreter will be used to add/remove mounts and volumes,
 *	it does cope with multiple interpreters in multiple threads.
 *	
 * Copyright (c) 2001 Vince Darley.
 * 
 * See the file "license.terms" for information on usage and redistribution
 * of this file, and for a DISCLAIMER OF ALL WARRANTIES.
 */

#include <tcl.h>
/* Required to access the 'stat' structure fields */
#include "tclPort.h"

/*
 * Windows needs to know which symbols to export.  Unix does not.
 * BUILD_Vfs should be undefined for Unix.
 */

#ifdef BUILD_Vfs
#undef TCL_STORAGE_CLASS
#define TCL_STORAGE_CLASS DLLEXPORT
#endif /* BUILD_Vfs */

/*
 * Only the _Init function is exported.
 */

EXTERN int Vfs_Init _ANSI_ARGS_((Tcl_Interp*));

/* 
 * Functions to add and remove a volume from the list of volumes.
 * These aren't currently exported, but could be in the future.
 */
static void Vfs_AddVolume    _ANSI_ARGS_((Tcl_Obj*));
static int  Vfs_RemoveVolume _ANSI_ARGS_((Tcl_Obj*));

/* 
 * Stores the list of volumes registered with the vfs (and therefore
 * also registered with Tcl).  It is maintained as a valid Tcl list at
 * all times, or NULL if there are none (we don't keep it as an empty
 * list just as a slight optimisation to improve Tcl's efficiency in
 * determining whether paths are absolute or relative).
 * 
 * We keep a refCount on this object whenever it is non-NULL.
 */
static Tcl_Obj *vfsVolumes = NULL;

/* 
 * Declare a mutex for thread-safety of modification of the
 * list of vfs volumes.
 */
TCL_DECLARE_MUTEX(vfsVolumesMutex)

/*
 * struct Vfs_InterpCmd --
 * 
 * Any vfs action which is exposed to Tcl requires both an interpreter
 * and a command prefix for evaluation.  To carry out any filesystem
 * action inside a vfs, this extension will lappend various additional
 * parameters to the command string, evaluate it in the interpreter and
 * then extract the result (the way the result is handled is documented
 * in each individual vfs callback below).
 * 
 * We retain a refCount on the 'mountCmd' object, but there is no need
 * for us to register our interpreter reference, since we will be
 * made invalid when the interpreter disappears.  Also, Tcl_Objs of
 * "path" type which use one of these structures as part of their
 * internal representation also do not need to add to any refCounts,
 * because if this object disappears, all internal representations will
 * be made invalid.
 */

typedef struct Vfs_InterpCmd {
    Tcl_Obj *mountCmd;    /* The Tcl command prefix which will be used
                           * to perform all filesystem actions on this
                           * file. */
    Tcl_Interp *interp;   /* The Tcl interpreter in which the above
                           * command will be evaluated. */
} Vfs_InterpCmd;

/*
 * struct VfsNativeRep --
 * 
 * Structure used for the native representation of a path in a Tcl vfs.
 * To fully specify a file, the string representation is also required.
 * 
 * When a Tcl interpreter is deleted, all mounts whose callbacks
 * are in it are removed and freed.  This also means that the
 * global filesystem epoch that Tcl retains is modified, and all
 * path internal representations are therefore discarded.  Therefore we
 * don't have to worry about vfs files containing stale VfsNativeRep
 * structures (but it also means we mustn't touch the fsCmd field
 * of one of these structures if the interpreter has gone).  This
 * means when we free one of these structures, we just free the
 * memory allocated, and ignore the fsCmd pointer (which may or may
 * not point to valid memory).
 */

typedef struct VfsNativeRep {
    int splitPosition;    /* The index into the string representation
                           * of the file which indicates where the 
                           * vfs filesystem is mounted. */
    Vfs_InterpCmd* fsCmd; /* The Tcl interpreter and command pair
                           * which will be used to perform all filesystem 
                           * actions on this file. */
} VfsNativeRep;

/*
 * struct VfsChannelCleanupInfo --
 * 
 * Structure we use to retain sufficient information about
 * a channel that we can properly clean up all resources
 * when the channel is closed.  This is required when using
 * 'open' on things inside the vfs.
 * 
 * When the channel in question is begin closed, we will
 * temporarily register the channel with the given interpreter,
 * evaluate the closeCallBack, and then detach the channel
 * from the interpreter and return (allowing Tcl to continue
 * closing the channel as normal).
 * 
 * Nothing in the callback can prevent the channel from
 * being closed.
 */

typedef struct VfsChannelCleanupInfo {
    Tcl_Channel channel;    /* The channel which needs cleaning up */
    Tcl_Obj* closeCallback; /* The Tcl command string to evaluate
                             * when the channel is closing, which will
                             * carry out any cleanup that is necessary. */
    Tcl_Interp* interp;     /* The interpreter in which to evaluate the
                             * cleanup operation. */
} VfsChannelCleanupInfo;


/*
 * Forward declarations for procedures defined later in this file:
 */

static int		 VfsFilesystemObjCmd _ANSI_ARGS_((ClientData dummy,
			    Tcl_Interp *interp, int objc, 
			    Tcl_Obj *CONST objv[]));

/* 
 * Now we define the virtual filesystem callbacks
 */

static Tcl_FSStatProc VfsStat;
static Tcl_FSAccessProc VfsAccess;
static Tcl_FSOpenFileChannelProc VfsOpenFileChannel;
static Tcl_FSMatchInDirectoryProc VfsMatchInDirectory;
static Tcl_FSDeleteFileProc VfsDeleteFile;
static Tcl_FSCreateDirectoryProc VfsCreateDirectory;
static Tcl_FSRemoveDirectoryProc VfsRemoveDirectory; 
static Tcl_FSFileAttrStringsProc VfsFileAttrStrings;
static Tcl_FSFileAttrsGetProc VfsFileAttrsGet;
static Tcl_FSFileAttrsSetProc VfsFileAttrsSet;
static Tcl_FSUtimeProc VfsUtime;
static Tcl_FSPathInFilesystemProc VfsInFilesystem;
static Tcl_FSFilesystemPathTypeProc VfsFilesystemPathType;
static Tcl_FSFilesystemSeparatorProc VfsFilesystemSeparator;
static Tcl_FSFreeInternalRepProc VfsFreeInternalRep;
static Tcl_FSDupInternalRepProc VfsDupInternalRep;
static Tcl_FSListVolumesProc VfsListVolumes;

static Tcl_Filesystem vfsFilesystem = {
    "tclvfs",
    sizeof(Tcl_Filesystem),
    TCL_FILESYSTEM_VERSION_1,
    &VfsInFilesystem,
    &VfsDupInternalRep,
    &VfsFreeInternalRep,
    /* No native to normalized */
    NULL,
    /* No create native rep function */
    NULL,
    /* normalize path isn't needed */
    NULL,
    &VfsFilesystemPathType,
    &VfsFilesystemSeparator,
    &VfsStat,
    &VfsAccess,
    &VfsOpenFileChannel,
    &VfsMatchInDirectory,
    &VfsUtime,
    /* link is not important  */
    NULL,
    &VfsListVolumes,
    &VfsFileAttrStrings,
    &VfsFileAttrsGet,
    &VfsFileAttrsSet,
    &VfsCreateDirectory,
    &VfsRemoveDirectory, 
    &VfsDeleteFile,
    /* Use stat for lstat */
    NULL,
    /* No copy file */
    NULL,
    /* No rename file */
    NULL,
    /* No copy directory */
    NULL, 
    /* No load */
    NULL,
    /* We don't need a getcwd or chdir */
    NULL,
    NULL
};

/*
 * struct VfsMount --
 * 
 * Each filesystem mount point which is registered will result in
 * the allocation of one of these structures.  They are stored
 * in a linked list whose head is 'listOfMounts'.
 */

typedef struct VfsMount {
    CONST char* mountPoint;
    int mountLen;
    int isVolume;
    Vfs_InterpCmd interpCmd;
    struct VfsMount* nextMount;
} VfsMount;

static VfsMount* listOfMounts = NULL;
/* 
 * Declare a mutex for thread-safety of modification of the
 * list of vfs mounts.
 */
TCL_DECLARE_MUTEX(vfsMountsMutex)

/* We might wish to consider exporting these in the future */

static int             Vfs_AddMount(Tcl_Obj* mountPoint, int isVolume, 
				    Tcl_Interp *interp, Tcl_Obj* mountCmd);
static int             Vfs_RemoveMount(Tcl_Obj* mountPoint, Tcl_Interp* interp);
static Vfs_InterpCmd*  Vfs_FindMount(CONST char* mountPoint);
static Tcl_Obj*        Vfs_ListMounts(void);
static void            Vfs_UnregisterWithInterp _ANSI_ARGS_((ClientData, 
							     Tcl_Interp*));
static void            Vfs_RegisterWithInterp _ANSI_ARGS_((Tcl_Interp*));

/* Some private helper procedures */

static VfsNativeRep*   VfsGetNativePath(Tcl_Obj* pathObjPtr);
static Tcl_CloseProc   VfsCloseProc;
static void            VfsExitProc(ClientData clientData);
static Tcl_Obj*        VfsCommand(Tcl_Interp **iRef, CONST char* cmd, 
				  Tcl_Obj * pathPtr);

/* 
 * Hard-code platform dependencies.  We do not need to worry 
 * about backslash-separators on windows, because a normalized
 * path will never contain them.
 */
#ifdef MAC_TCL
    #define VFS_SEPARATOR ':'
#else
    #define VFS_SEPARATOR '/'
#endif


/*
 *----------------------------------------------------------------------
 *
 * Vfs_Init --
 *
 *	This procedure is the main initialisation point of the Vfs
 *	extension.
 *
 * Results:
 *	Returns a standard Tcl completion code, and leaves an error
 *	message in the interp's result if an error occurs.
 *
 * Side effects:
 *	Adds a command to the Tcl interpreter.
 *
 *----------------------------------------------------------------------
 */

int
Vfs_Init(interp)
    Tcl_Interp *interp;		/* Interpreter for application. */
{
    if (Tcl_InitStubs(interp, "8.4", 0) == NULL) {
	return TCL_ERROR;
    }
    if (Tcl_PkgRequire(interp, "Tcl", "8.4", 0) == NULL) {
	return TCL_ERROR;
    }
    /* 
     * Safe interpreters are not allowed to modify the filesystem!
     * (Since those modifications will affect other interpreters).
     */
    if (Tcl_IsSafe(interp)) {
        return TCL_ERROR;
    }
    if (Tcl_PkgProvide(interp, "vfs", "1.0") == TCL_ERROR) {
        return TCL_ERROR;
    }

    /*
     * Create 'vfs::filesystem' command, and interpreter-specific
     * initialisation.
     */

    Tcl_CreateObjCommand(interp, "vfs::filesystem", VfsFilesystemObjCmd, 
	    (ClientData) NULL, (Tcl_CmdDeleteProc *) NULL);
    Vfs_RegisterWithInterp(interp);
    return TCL_OK;
}


/*
 *----------------------------------------------------------------------
 *
 * Vfs_RegisterWithInterp --
 *
 *	Allow the given interpreter to be used to handle vfs callbacks.
 *
 * Results:
 *	None.
 *
 * Side effects:
 *	May register the entire vfs code (if not previously registered).
 *	Registers some cleanup action for when this interpreter is
 *	deleted.
 *
 *----------------------------------------------------------------------
 */
static void 
Vfs_RegisterWithInterp(interp)
    Tcl_Interp *interp;
{
    ClientData vfsAlreadyRegistered;
    /* 
     * We need to know if the interpreter is deleted, so we can
     * remove all interp-specific mounts.
     */
    Tcl_SetAssocData(interp, "vfs::inUse", (Tcl_InterpDeleteProc*) 
		     Vfs_UnregisterWithInterp, (ClientData) 1);
    /* 
     * Perform one-off registering of our filesystem if that
     * has not happened before.
     */
    vfsAlreadyRegistered = Tcl_FSData(&vfsFilesystem);
    if (vfsAlreadyRegistered == NULL) {
	Tcl_FSRegister((ClientData)1, &vfsFilesystem);
	Tcl_CreateExitHandler(VfsExitProc, (ClientData)NULL);
    }
}
   

/*
 *----------------------------------------------------------------------
 *
 * Vfs_UnregisterWithInterp --
 *
 *	Remove all of the mount points that this interpreter handles.
 *
 * Results:
 *	None.
 *
 * Side effects:
 *	None.
 *
 *----------------------------------------------------------------------
 */
static void 
Vfs_UnregisterWithInterp(dummy, interp)
    ClientData dummy;
    Tcl_Interp *interp;
{
    int res = TCL_OK;
    /* Remove all of this interpreters mount points */
    while (res == TCL_OK) {
        res = Vfs_RemoveMount(NULL, interp);
    }
    /* Make sure our assoc data has been deleted */
    Tcl_DeleteAssocData(interp, "vfs::inUse");
}


/*
 *----------------------------------------------------------------------
 *
 * Vfs_AddMount --
 *
 *	Adds a new vfs mount point.  After this call all filesystem
 *	access within that mount point will be redirected to the
 *	interpreter/mountCmd pair.
 *	
 *	This command must not be called unless 'interp' has already
 *	been registered with 'Vfs_RegisterWithInterp' above.  This 
 *	usually happens automatically with a 'package require vfs'.
 *
 * Results:
 *	TCL_OK unless the inputs are bad or a memory allocation
 *	error occurred, or the interpreter is not vfs-registered.
 *
 * Side effects:
 *	A new volume may be added to the list of available volumes.
 *	Future filesystem access inside the mountPoint will be 
 *	redirected.  Tcl is informed that a new mount has been added
 *	and this will make all cached path representations invalid.
 *
 *----------------------------------------------------------------------
 */
static int 
Vfs_AddMount(mountPoint, isVolume, interp, mountCmd)
    Tcl_Obj* mountPoint;
    int isVolume;
    Tcl_Interp* interp;
    Tcl_Obj* mountCmd;
{
    char *strRep;
    int len;
    VfsMount *newMount;
    
    if (mountPoint == NULL || interp == NULL || mountCmd == NULL) {
	return TCL_ERROR;
    }
    /* 
     * Check whether this intepreter can properly clean up
     * mounts on exit.  If not, throw an error.
     */
    if (Tcl_GetAssocData(interp, "vfs::inUse", NULL) == NULL) {
        return TCL_ERROR;
    }
    
    newMount = (VfsMount*) ckalloc(sizeof(VfsMount));
    
    if (newMount == NULL) {
	return TCL_ERROR;
    }
    strRep = Tcl_GetStringFromObj(mountPoint, &len);
    newMount->mountPoint = (char*) ckalloc(1+len);
    newMount->mountLen = len;
    
    if (newMount->mountPoint == NULL) {
	ckfree((char*)newMount);
	return TCL_ERROR;
    }
    
    strcpy((char*)newMount->mountPoint, strRep);
    newMount->interpCmd.mountCmd = mountCmd;
    newMount->interpCmd.interp = interp;
    newMount->isVolume = isVolume;
    Tcl_IncrRefCount(mountCmd);
    
    Tcl_MutexLock(&vfsMountsMutex);
    newMount->nextMount = listOfMounts;
    listOfMounts = newMount;
    Tcl_MutexUnlock(&vfsMountsMutex);

    if (isVolume) {
	Vfs_AddVolume(mountPoint);
    }
    Tcl_FSMountsChanged(&vfsFilesystem);
    return TCL_OK;
}


/*
 *----------------------------------------------------------------------
 *
 * Vfs_RemoveMount --
 *
 *	This procedure searches for a matching mount point and removes
 *	it if one is found.  If 'mountPoint' is given, then both it and
 *	the interpreter must match for a mount point to be removed.
 *	
 *	If 'mountPoint' is NULL, then the first mount point for the
 *	given interpreter is removed (if any).
 *
 * Results:
 *	TCL_OK if a mount was removed, TCL_ERROR otherwise.
 *
 * Side effects:
 *	A volume may be removed from the current list of volumes
 *	(as returned by 'file volumes').  A vfs may be removed from
 *	the filesystem.  If successful, Tcl will be informed that
 *	the list of current mounts has changed, and all cached file
 *	representations will be made invalid.
 *
 *----------------------------------------------------------------------
 */
static int 
Vfs_RemoveMount(mountPoint, interp)
    Tcl_Obj* mountPoint;
    Tcl_Interp *interp;
{
    /* These two are only used if mountPoint is non-NULL */
    char *strRep = NULL;
    int len = 0;
    
    VfsMount *mountIter;
    /* Set to NULL just to avoid warnings */
    VfsMount *lastMount = NULL;
    
    if (mountPoint != NULL) {
	strRep = Tcl_GetStringFromObj(mountPoint, &len);
    }
       
    Tcl_MutexLock(&vfsMountsMutex);
    mountIter = listOfMounts;
    
    while (mountIter != NULL) {
	if ((interp == mountIter->interpCmd.interp) 
	    && ((mountPoint == NULL) ||
		(mountIter->mountLen == len && 
		 !strcmp(mountIter->mountPoint, strRep)))) {
	    /* We've found the mount. */
	    if (mountIter == listOfMounts) {
		listOfMounts = mountIter->nextMount;
	    } else {
		lastMount->nextMount = mountIter->nextMount;
	    }
	    /* Free the allocated memory */
	    if (mountIter->isVolume) {
		if (mountPoint == NULL) {
		    Tcl_Obj *volObj = Tcl_NewStringObj(mountIter->mountPoint, 
						       mountIter->mountLen);
		    Tcl_IncrRefCount(volObj);
		    Vfs_RemoveVolume(volObj);
		    Tcl_DecrRefCount(volObj);
		} else {
		    Vfs_RemoveVolume(mountPoint);
		}
	    }
	    ckfree((char*)mountIter->mountPoint);
	    Tcl_DecrRefCount(mountIter->interpCmd.mountCmd);
	    ckfree((char*)mountIter);
	    Tcl_FSMountsChanged(&vfsFilesystem);
	    Tcl_MutexUnlock(&vfsMountsMutex);
	    return TCL_OK;
	}
	lastMount = mountIter;
	mountIter = mountIter->nextMount;
    }
    Tcl_MutexUnlock(&vfsMountsMutex);
    return TCL_ERROR;
}


/*
 *----------------------------------------------------------------------
 *
 * Vfs_FindMount --
 *
 *	This procedure is searches all currently mounted paths for
 *	one which matches the given path.  The given path should
 *	be the absolute, normalized, unique string for the given
 *	path.
 *
 * Results:
 *	Returns the interpreter, command-prefix pair for the given
 *	mount point, if one is found, otherwise NULL.
 *
 * Side effects:
 *	None.
 *
 *----------------------------------------------------------------------
 */
static Vfs_InterpCmd* 
Vfs_FindMount(mountPoint)
    CONST char* mountPoint;
{
    VfsMount *mountIter;
    int len;
    
    if (mountPoint == NULL) {
	return NULL;
    }
    
    len = strlen(mountPoint);
    
    Tcl_MutexLock(&vfsMountsMutex);

    mountIter = listOfMounts;
    while (mountIter != NULL) {
	if (mountIter->mountLen == len && 
	  !strcmp(mountIter->mountPoint, mountPoint)) {
	    Vfs_InterpCmd *ret = &mountIter->interpCmd;
	    Tcl_MutexUnlock(&vfsMountsMutex);
	    return ret;
	}
	mountIter = mountIter->nextMount;
    }
    Tcl_MutexUnlock(&vfsMountsMutex);
    return NULL;
}


/*
 *----------------------------------------------------------------------
 *
 * Vfs_ListMounts --
 *
 *	Returns a valid Tcl list, with refCount of zero, containing
 *	all currently mounted paths.
 *	
 *----------------------------------------------------------------------
 */
static Tcl_Obj* 
Vfs_ListMounts(void) 
{
    VfsMount *mountIter;
    Tcl_Obj *res = Tcl_NewObj();

    Tcl_MutexLock(&vfsMountsMutex);

    /* Build list of mounts */
    mountIter = listOfMounts;
    while (mountIter != NULL) {
	Tcl_Obj* mount = Tcl_NewStringObj(mountIter->mountPoint, 
					  mountIter->mountLen);
	Tcl_ListObjAppendElement(NULL, res, mount);
	mountIter = mountIter->nextMount;
    }
    Tcl_MutexUnlock(&vfsMountsMutex);
    return res;
}


/*
 *----------------------------------------------------------------------
 *
 * VfsFilesystemObjCmd --
 *
 *	This procedure implements the "vfs::filesystem" command.  It is
 *	used to mount/unmount particular interfaces to new filesystems,
 *	or to query for what is mounted where.
 *
 * Results:
 *	A standard Tcl result.
 *
 * Side effects:
 *	Inserts or removes a filesystem from Tcl's stack.
 *
 *----------------------------------------------------------------------
 */

static int
VfsFilesystemObjCmd(dummy, interp, objc, objv)
    ClientData dummy;
    Tcl_Interp *interp;
    int		objc;
    Tcl_Obj	*CONST objv[];
{
    int index;

    static char *optionStrings[] = {
	"info", "mount", "unmount",
	NULL
    };
    enum options {
	VFS_INFO, VFS_MOUNT, VFS_UNMOUNT,
    };

    if (objc < 2) {
	Tcl_WrongNumArgs(interp, 1, objv, "option ?arg ...?");
	return TCL_ERROR;
    }
    if (Tcl_GetIndexFromObj(interp, objv[1], optionStrings, "option", 0,
	    &index) != TCL_OK) {
	return TCL_ERROR;
    }

    switch ((enum options) index) {
	case VFS_MOUNT: {
	    int i;
	    if (objc < 4 || objc > 5) {
		Tcl_WrongNumArgs(interp, 1, objv, "mount ?-volume? path cmd");
		return TCL_ERROR;
	    }
	    if (objc == 5) {
		char *option = Tcl_GetString(objv[2]);
		if (strcmp("-volume", option)) {
		    Tcl_AppendStringsToObj(Tcl_GetObjResult(interp),
			    "bad option \"", option,
			    "\": must be -volume", (char *) NULL);
		    return TCL_ERROR;
		}
		i = 3;
		return Vfs_AddMount(objv[i], 1, interp, objv[i+1]);
	    } else {
		Tcl_Obj *path;
		i = 2;
		path = Tcl_FSGetNormalizedPath(interp, objv[i]);
		return Vfs_AddMount(path, 0, interp, objv[i+1]);
	    }
	    break;
	}
	case VFS_INFO: {
	    if (objc > 3) {
		Tcl_WrongNumArgs(interp, 2, objv, "path");
		return TCL_ERROR;
	    }
	    if (objc == 2) {
		Tcl_SetObjResult(interp, Vfs_ListMounts());
	    } else {
		Vfs_InterpCmd *val;
		
		val = Vfs_FindMount(Tcl_GetString(objv[2]));
		if (val == NULL) {
		    Tcl_Obj *path = Tcl_FSGetNormalizedPath(interp, objv[2]);
		    val = Vfs_FindMount(Tcl_GetString(path));
		    if (val == NULL) {
			Tcl_AppendStringsToObj(Tcl_GetObjResult(interp),
				"no such mount \"", Tcl_GetString(objv[2]), 
				"\"", (char *) NULL);
			return TCL_ERROR;
		    }
		}
		Tcl_SetObjResult(interp, val->mountCmd);
	    }
	    break;
	}
	case VFS_UNMOUNT: {
	    if (objc != 3) {
		Tcl_WrongNumArgs(interp, 2, objv, "path");
		return TCL_ERROR;
	    }
	    if (Vfs_RemoveMount(objv[2], interp) == TCL_ERROR) {
		Tcl_Obj * path;
		path = Tcl_FSGetNormalizedPath(interp, objv[2]);
		if (Vfs_RemoveMount(path, interp) == TCL_ERROR) {
		    Tcl_AppendStringsToObj(Tcl_GetObjResult(interp),
			    "no such mount \"", Tcl_GetString(objv[2]), 
			    "\"", (char *) NULL);
		    return TCL_ERROR;
		}
	    }
	    return TCL_OK;
	}
    }
    return TCL_OK;
}


static int 
VfsInFilesystem(Tcl_Obj *pathPtr, ClientData *clientDataPtr) {
    Tcl_Obj *normedObj;
    int len, splitPosition;
    /* Just set this to avoid a warning */
    char remember = '\0';
    char *normed;
    VfsNativeRep *nativeRep;
    Vfs_InterpCmd *interpCmd = NULL;
    
    if (TclInExit()) {
	/* 
	 * Even Tcl_FSGetNormalizedPath may fail due to lack of system
	 * encodings, so we just say we can't handle anything if we are
	 * in the middle of the exit sequence.  We could perhaps be
	 * more subtle than this!
	 */
	return -1;
    }

    normedObj = Tcl_FSGetNormalizedPath(NULL, pathPtr);
    if (normedObj == NULL) {
        return -1;
    }
    normed = Tcl_GetStringFromObj(normedObj, &len);
    splitPosition = len;

    /* 
     * Find the most specific mount point for this path.
     * Mount points are specified by unique strings, so
     * we have to use a unique normalised path for the
     * checks here.
     */
    while (interpCmd == NULL) {
	interpCmd = Vfs_FindMount(normed);
	if (interpCmd != NULL) break;

	if (splitPosition != len) {
	    normed[splitPosition] = VFS_SEPARATOR;
	}
	while ((splitPosition > 0) 
	       && (normed[--splitPosition] != VFS_SEPARATOR)) {
	    /* Do nothing */
	}
	/* 
	 * We now know that normed[splitPosition] is a separator.
	 * However, we might have mounted a root filesystem with a
	 * strange name (for example 'ftp://')
	 */
	if ((splitPosition > 0) && (splitPosition != len)) {
	    remember = normed[splitPosition + 1];
	    normed[splitPosition+1] = '\0';
	    interpCmd = Vfs_FindMount(normed);
				     
	    if (interpCmd != NULL) {
		splitPosition++;
		break;
	    }
	    normed[splitPosition+1] = remember;
	}
	
	/* Otherwise continue as before */
	
	/* Terminate the string there */
	if (splitPosition == 0) {
	    break;
	}
	remember = VFS_SEPARATOR;
	normed[splitPosition] = 0;
    }
    
    /* 
     * Now either splitPosition is zero, or we found a mount point.
     * Test for both possibilities, just to be sure.
     */
    if ((splitPosition == 0) || (interpCmd == NULL)) {
	return -1;
    }
    if (splitPosition != len) {
	normed[splitPosition] = remember;
    }
    nativeRep = (VfsNativeRep*) ckalloc(sizeof(VfsNativeRep));
    nativeRep->splitPosition = splitPosition;
    nativeRep->fsCmd = interpCmd;
    *clientDataPtr = (ClientData)nativeRep;
    return TCL_OK;
}

/* 
 * Simple helper function to extract the native vfs representation of a
 * path object, or NULL if no such representation exists.
 */
static VfsNativeRep* 
VfsGetNativePath(Tcl_Obj* pathObjPtr) {
    return (VfsNativeRep*) Tcl_FSGetInternalRep(pathObjPtr, &vfsFilesystem);
}

static void 
VfsFreeInternalRep(ClientData clientData) {
    VfsNativeRep *nativeRep = (VfsNativeRep*)clientData;
    if (nativeRep != NULL) {
	/* Free the native memory allocation */
	ckfree((char*)nativeRep);
    }
}

static ClientData 
VfsDupInternalRep(ClientData clientData) {
    VfsNativeRep *original = (VfsNativeRep*)clientData;

    VfsNativeRep *nativeRep = (VfsNativeRep*) ckalloc(sizeof(VfsNativeRep));
    nativeRep->splitPosition = original->splitPosition;
    nativeRep->fsCmd = original->fsCmd;
    
    return (ClientData)nativeRep;
}

static Tcl_Obj* 
VfsFilesystemPathType(Tcl_Obj *pathPtr) {
    VfsNativeRep* nativeRep = VfsGetNativePath(pathPtr);
    if (nativeRep == NULL) {
	return NULL;
    } else {
	return nativeRep->fsCmd->mountCmd;
    }
}

static Tcl_Obj*
VfsFilesystemSeparator(Tcl_Obj* pathObjPtr) {
    return Tcl_NewStringObj("/",1);
}

static int
VfsStat(pathPtr, bufPtr)
    Tcl_Obj *pathPtr;		/* Path of file to stat (in current CP). */
    struct stat *bufPtr;	/* Filled with results of stat call. */
{
    Tcl_Obj *mountCmd = NULL;
    Tcl_SavedResult savedResult;
    int returnVal;
    Tcl_Interp* interp;
    
    mountCmd = VfsCommand(&interp, "stat", pathPtr);
    if (mountCmd == NULL) {
	return -1;
    }

    Tcl_SaveResult(interp, &savedResult);
    /* Now we execute this mount point's callback. */
    returnVal = Tcl_EvalObjEx(interp, mountCmd, 
			      TCL_EVAL_GLOBAL | TCL_EVAL_DIRECT);
    if (returnVal == TCL_OK) {
	int statListLength;
	Tcl_Obj* resPtr = Tcl_GetObjResult(interp);
	if (Tcl_ListObjLength(interp, resPtr, &statListLength) == TCL_ERROR) {
	    returnVal = TCL_ERROR;
	} else if (statListLength & 1) {
	    /* It is odd! */
	    returnVal = TCL_ERROR;
	} else {
	    /* 
	     * The st_mode field is set part by the 'mode'
	     * and part by the 'type' stat fields.
	     */
	    bufPtr->st_mode = 0;
	    while (statListLength > 0) {
		Tcl_Obj *field, *val;
		char *fieldName;
		statListLength -= 2;
		Tcl_ListObjIndex(interp, resPtr, statListLength, &field);
		Tcl_ListObjIndex(interp, resPtr, statListLength+1, &val);
		fieldName = Tcl_GetString(field);
		if (!strcmp(fieldName,"dev")) {
		    long v;
		    if (Tcl_GetLongFromObj(interp, val, &v) != TCL_OK) {
			returnVal = TCL_ERROR;
			break;
		    }
		    bufPtr->st_dev = v;
		} else if (!strcmp(fieldName,"ino")) {
		    long v;
		    if (Tcl_GetLongFromObj(interp, val, &v) != TCL_OK) {
			returnVal = TCL_ERROR;
			break;
		    }
		    bufPtr->st_ino = (unsigned short)v;
		} else if (!strcmp(fieldName,"mode")) {
		    int v;
		    if (Tcl_GetIntFromObj(interp, val, &v) != TCL_OK) {
			returnVal = TCL_ERROR;
			break;
		    }
		    bufPtr->st_mode |= v;
		} else if (!strcmp(fieldName,"nlink")) {
		    long v;
		    if (Tcl_GetLongFromObj(interp, val, &v) != TCL_OK) {
			returnVal = TCL_ERROR;
			break;
		    }
		    bufPtr->st_nlink = (short)v;
		} else if (!strcmp(fieldName,"uid")) {
		    long v;
		    if (Tcl_GetLongFromObj(interp, val, &v) != TCL_OK) {
			returnVal = TCL_ERROR;
			break;
		    }
		    bufPtr->st_uid = (short)v;
		} else if (!strcmp(fieldName,"gid")) {
		    long v;
		    if (Tcl_GetLongFromObj(interp, val, &v) != TCL_OK) {
			returnVal = TCL_ERROR;
			break;
		    }
		    bufPtr->st_gid = (short)v;
		} else if (!strcmp(fieldName,"size")) {
		    long v;
		    if (Tcl_GetLongFromObj(interp, val, &v) != TCL_OK) {
			returnVal = TCL_ERROR;
			break;
		    }
		    bufPtr->st_size = v;
		} else if (!strcmp(fieldName,"atime")) {
		    long v;
		    if (Tcl_GetLongFromObj(interp, val, &v) != TCL_OK) {
			returnVal = TCL_ERROR;
			break;
		    }
		    bufPtr->st_atime = v;
		} else if (!strcmp(fieldName,"mtime")) {
		    long v;
		    if (Tcl_GetLongFromObj(interp, val, &v) != TCL_OK) {
			returnVal = TCL_ERROR;
			break;
		    }
		    bufPtr->st_mtime = v;
		} else if (!strcmp(fieldName,"ctime")) {
		    long v;
		    if (Tcl_GetLongFromObj(interp, val, &v) != TCL_OK) {
			returnVal = TCL_ERROR;
			break;
		    }
		    bufPtr->st_ctime = v;
		} else if (!strcmp(fieldName,"type")) {
		    char *str;
		    str = Tcl_GetString(val);
		    if (!strcmp(str,"directory")) {
			bufPtr->st_mode |= S_IFDIR;
		    } else if (!strcmp(str,"file")) {
			bufPtr->st_mode |= S_IFREG;
		    } else {
			/* 
			 * Do nothing.  This means we do not currently
			 * support anything except files and directories
			 */
		    }
		} else {
		    /* Ignore additional stat arguments */
		}
	    }
	}
    }
    
    Tcl_RestoreResult(interp, &savedResult);
    Tcl_DecrRefCount(mountCmd);
    
    if (returnVal != 0) {
	Tcl_SetErrno(ENOENT);
        return -1;
    } else {
	return returnVal;
    }
}

int
VfsAccess(pathPtr, mode)
    Tcl_Obj *pathPtr;		/* Path of file to access (in current CP). */
    int mode;                   /* Permission setting. */
{
    Tcl_Obj *mountCmd = NULL;
    Tcl_SavedResult savedResult;
    int returnVal;
    Tcl_Interp* interp;
    
    mountCmd = VfsCommand(&interp, "access", pathPtr);
    if (mountCmd == NULL) {
	return -1;
    }

    Tcl_ListObjAppendElement(interp, mountCmd, Tcl_NewIntObj(mode));
    /* Now we execute this mount point's callback. */
    Tcl_SaveResult(interp, &savedResult);
    returnVal = Tcl_EvalObjEx(interp, mountCmd, 
			      TCL_EVAL_GLOBAL | TCL_EVAL_DIRECT);
    Tcl_RestoreResult(interp, &savedResult);
    Tcl_DecrRefCount(mountCmd);

    if (returnVal != 0) {
	Tcl_SetErrno(ENOENT);
	return -1;
    } else {
	return returnVal;
    }
}

Tcl_Channel
VfsOpenFileChannel(cmdInterp, pathPtr, modeString, permissions)
    Tcl_Interp *cmdInterp;              /* Interpreter for error reporting;
					 * can be NULL. */
    Tcl_Obj *pathPtr;                   /* Name of file to open. */
    char *modeString;                   /* A list of POSIX open modes or
					 * a string such as "rw". */
    int permissions;                    /* If the open involves creating a
					 * file, with what modes to create
					 * it? */
{
    Tcl_Channel chan = NULL;
    Tcl_Obj *mountCmd = NULL;
    Tcl_Obj *closeCallback = NULL;
    Tcl_SavedResult savedResult;
    int returnVal;
    Tcl_Interp* interp;
    
    mountCmd = VfsCommand(&interp, "open", pathPtr);
    if (mountCmd == NULL) {
	return NULL;
    }

    Tcl_ListObjAppendElement(interp, mountCmd, Tcl_NewStringObj(modeString,-1));
    Tcl_ListObjAppendElement(interp, mountCmd, Tcl_NewIntObj(permissions));
    Tcl_SaveResult(interp, &savedResult);
    /* Now we execute this mount point's callback. */
    returnVal = Tcl_EvalObjEx(interp, mountCmd, 
			      TCL_EVAL_GLOBAL | TCL_EVAL_DIRECT);
    if (returnVal == TCL_OK) {
	int reslen;
	Tcl_Obj *resultObj;
	/* 
	 * There may be file channel leaks on these two 
	 * error conditions, if the open command actually
	 * created a channel, but then passed us a bogus list.
	 */
	resultObj =  Tcl_GetObjResult(interp);
	if ((Tcl_ListObjLength(interp, resultObj, &reslen) == TCL_ERROR) 
	  || (reslen > 2) || (reslen == 0)) {
	    returnVal = TCL_ERROR;
	} else {
	    Tcl_Obj *element;
	    Tcl_ListObjIndex(interp, resultObj, 0, &element);
	    chan = Tcl_GetChannel(interp, Tcl_GetString(element), 0);
	    
	    if (chan == NULL) {
	        returnVal = TCL_ERROR;
	    } else {
		if (reslen == 2) {
		    Tcl_ListObjIndex(interp, resultObj, 1, &element);
		    closeCallback = element;
		    Tcl_IncrRefCount(closeCallback);
		}
	    }
	}
	Tcl_RestoreResult(interp, &savedResult);
    } else {
	/* Leave an error message if the cmdInterp is non NULL */
	if (cmdInterp != NULL) {
	    int posixError = -1;
	    Tcl_Obj* error = Tcl_GetObjResult(interp);
	    if (Tcl_GetIntFromObj(NULL, error, &posixError) == TCL_OK) {
		Tcl_SetErrno(posixError);
		Tcl_ResetResult(cmdInterp);
		Tcl_AppendResult(cmdInterp, "couldn't open \"", 
				 Tcl_GetString(pathPtr), "\": ",
				 Tcl_PosixError(interp), (char *) NULL);
				 
	    } else {
		/* 
		 * Copy over the error message to cmdInterp,
		 * duplicating it in case of threading issues.
		 */
		Tcl_SetObjResult(cmdInterp, Tcl_DuplicateObj(error));
	    }
	}
	if (interp == cmdInterp) {
	    /* 
	     * We want our error message to propagate up,
	     * so we want to forget this result
	     */
	    Tcl_DiscardResult(&savedResult);
	} else {
	    Tcl_RestoreResult(interp, &savedResult);
	}
    }

    Tcl_DecrRefCount(mountCmd);

    if (chan != NULL) {
	/*
	 * We got the Channel from some Tcl code.  This means it was
	 * registered with the interpreter.  But we want a pristine
	 * channel which hasn't been registered with anyone.  We use
	 * Tcl_DetachChannel to do this for us.  We must use the
	 * correct interpreter.
	 */
	Tcl_DetachChannel(interp, chan);
	
	if (closeCallback != NULL) {
	    VfsChannelCleanupInfo *channelRet = NULL;
	    channelRet = (VfsChannelCleanupInfo*) 
			    ckalloc(sizeof(VfsChannelCleanupInfo));
	    channelRet->channel = chan;
	    channelRet->interp = interp;
	    channelRet->closeCallback = closeCallback;
	    /* The channelRet structure will be freed in the callback */
	    Tcl_CreateCloseHandler(chan, &VfsCloseProc, (ClientData)channelRet);
	}
    }
    return chan;
}

/* 
 * IMPORTANT: This procedure must *not* modify the interpreter's result
 * this leads to the objResultPtr being corrupted (somehow), and curious
 * crashes in the future (which are very hard to debug ;-).
 * 
 * This is particularly important since we are evaluating arbitrary
 * Tcl code in the callback.
 * 
 * Also note we are relying on the close-callback to occur just before
 * the channel is about to be properly closed, but after all output
 * has been flushed.  That way we can, in the callback, read in the
 * entire contents of the channel and, say, compress it for storage
 * into a tclkit or zip archive.
 */
void 
VfsCloseProc(ClientData clientData) {
    VfsChannelCleanupInfo * channelRet = (VfsChannelCleanupInfo*) clientData;
    Tcl_SavedResult savedResult;
    Tcl_Channel chan = channelRet->channel;
    Tcl_Interp * interp = channelRet->interp;

    Tcl_SaveResult(interp, &savedResult);

    /* 
     * The interpreter needs to know about the channel, else the Tcl
     * callback will fail, so we register the channel (this allows
     * the Tcl code to use the channel's string-name).
     */
    Tcl_RegisterChannel(interp, chan);
    Tcl_EvalObjEx(interp, channelRet->closeCallback, 
		  TCL_EVAL_GLOBAL | TCL_EVAL_DIRECT);
    Tcl_DecrRefCount(channelRet->closeCallback);

    /* 
     * More complications; we can't just unregister the channel,
     * because it is in the middle of being cleaned up, and the cleanup
     * code doesn't like a channel to be closed again while it is
     * already being closed.  So, we do the same trick as above to
     * unregister it without cleanup.
     */
    Tcl_DetachChannel(interp, chan);

    Tcl_RestoreResult(interp, &savedResult);
    ckfree((char*)channelRet);
}

int
VfsMatchInDirectory(
    Tcl_Interp *cmdInterp,	/* Interpreter to receive results. */
    Tcl_Obj *returnPtr,		/* Interpreter to receive results. */
    Tcl_Obj *dirPtr,	        /* Contains path to directory to search. */
    char *pattern,		/* Pattern to match against. */
    Tcl_GlobTypeData *types)	/* Object containing list of acceptable types.
				 * May be NULL. */
{
    Tcl_Obj *mountCmd = NULL;
    Tcl_SavedResult savedResult;
    int returnVal;
    Tcl_Interp* interp;
    int type = 0;
    Tcl_Obj *vfsResultPtr = NULL;
    
    mountCmd = VfsCommand(&interp, "matchindirectory", dirPtr);
    if (mountCmd == NULL) {
	return -1;
    }

    if (types != NULL) {
	type = types->type;
    }

    Tcl_ListObjAppendElement(interp, mountCmd, Tcl_NewStringObj(pattern,-1));
    Tcl_ListObjAppendElement(interp, mountCmd, Tcl_NewIntObj(type));
    Tcl_SaveResult(interp, &savedResult);
    /* Now we execute this mount point's callback. */
    returnVal = Tcl_EvalObjEx(interp, mountCmd, 
			      TCL_EVAL_GLOBAL | TCL_EVAL_DIRECT);
    if (returnVal != -1) {
	vfsResultPtr = Tcl_DuplicateObj(Tcl_GetObjResult(interp));
    }
    Tcl_RestoreResult(interp, &savedResult);
    Tcl_DecrRefCount(mountCmd);

    if (vfsResultPtr != NULL) {
	if (returnVal == TCL_OK) {
	    Tcl_IncrRefCount(vfsResultPtr);
	    Tcl_ListObjAppendList(cmdInterp, returnPtr, vfsResultPtr);
	    Tcl_DecrRefCount(vfsResultPtr);
	} else {
	    Tcl_SetObjResult(cmdInterp, vfsResultPtr);
	}
    }
    
    return returnVal;
}

int
VfsDeleteFile(
    Tcl_Obj *pathPtr)		/* Pathname of file to be removed (UTF-8). */
{
    Tcl_Obj *mountCmd = NULL;
    Tcl_SavedResult savedResult;
    int returnVal;
    Tcl_Interp* interp;
    
    mountCmd = VfsCommand(&interp, "deletefile", pathPtr);
    if (mountCmd == NULL) {
	return -1;
    }

    /* Now we execute this mount point's callback. */
    Tcl_SaveResult(interp, &savedResult);
    returnVal = Tcl_EvalObjEx(interp, mountCmd, 
			      TCL_EVAL_GLOBAL | TCL_EVAL_DIRECT);
    Tcl_RestoreResult(interp, &savedResult);
    Tcl_DecrRefCount(mountCmd);
    return returnVal;
}

int
VfsCreateDirectory(
    Tcl_Obj *pathPtr)		/* Pathname of directory to create (UTF-8). */
{
    Tcl_Obj *mountCmd = NULL;
    Tcl_SavedResult savedResult;
    int returnVal;
    Tcl_Interp* interp;
    
    mountCmd = VfsCommand(&interp, "createdirectory", pathPtr);
    if (mountCmd == NULL) {
	return -1;
    }

    /* Now we execute this mount point's callback. */
    Tcl_SaveResult(interp, &savedResult);
    returnVal = Tcl_EvalObjEx(interp, mountCmd, 
			      TCL_EVAL_GLOBAL | TCL_EVAL_DIRECT);
    Tcl_RestoreResult(interp, &savedResult);
    Tcl_DecrRefCount(mountCmd);
    return returnVal;
}

int
VfsRemoveDirectory(
    Tcl_Obj *pathPtr,		/* Pathname of directory to be removed
				 * (UTF-8). */
    int recursive,		/* If non-zero, removes directories that
				 * are nonempty.  Otherwise, will only remove
				 * empty directories. */
    Tcl_Obj **errorPtr)	        /* Location to store name of file
				 * causing error. */
{
    Tcl_Obj *mountCmd = NULL;
    Tcl_SavedResult savedResult;
    int returnVal;
    Tcl_Interp* interp;
    
    mountCmd = VfsCommand(&interp, "removedirectory", pathPtr);
    if (mountCmd == NULL) {
	return -1;
    }

    Tcl_ListObjAppendElement(interp, mountCmd, Tcl_NewIntObj(recursive));
    /* Now we execute this mount point's callback. */
    Tcl_SaveResult(interp, &savedResult);
    returnVal = Tcl_EvalObjEx(interp, mountCmd, 
			      TCL_EVAL_GLOBAL | TCL_EVAL_DIRECT);
    Tcl_RestoreResult(interp, &savedResult);
    Tcl_DecrRefCount(mountCmd);

    if (returnVal == TCL_ERROR) {
	/* Assume there was a problem with the directory being non-empty */
        if (errorPtr != NULL) {
            *errorPtr = pathPtr;
	    Tcl_IncrRefCount(*errorPtr);
        }
	Tcl_SetErrno(EEXIST);
    }
    return returnVal;
}

char**
VfsFileAttrStrings(pathPtr, objPtrRef)
    Tcl_Obj* pathPtr;
    Tcl_Obj** objPtrRef;
{
    Tcl_Obj *mountCmd = NULL;
    Tcl_SavedResult savedResult;
    int returnVal;
    Tcl_Interp* interp;
    
    mountCmd = VfsCommand(&interp, "fileattributes", pathPtr);
    if (mountCmd == NULL) {
	*objPtrRef = NULL;
	return NULL;
    }

    Tcl_SaveResult(interp, &savedResult);
    /* Now we execute this mount point's callback. */
    returnVal = Tcl_EvalObjEx(interp, mountCmd, 
			      TCL_EVAL_GLOBAL | TCL_EVAL_DIRECT);
    if (returnVal == TCL_OK) {
	*objPtrRef = Tcl_DuplicateObj(Tcl_GetObjResult(interp));
    } else {
	*objPtrRef = NULL;
    }
    Tcl_RestoreResult(interp, &savedResult);
    Tcl_DecrRefCount(mountCmd);
    return NULL;
}

int
VfsFileAttrsGet(cmdInterp, index, pathPtr, objPtrRef)
    Tcl_Interp *cmdInterp;	/* The interpreter for error reporting. */
    int index;			/* index of the attribute command. */
    Tcl_Obj *pathPtr;		/* filename we are operating on. */
    Tcl_Obj **objPtrRef;	/* for output. */
{
    Tcl_Obj *mountCmd = NULL;
    Tcl_SavedResult savedResult;
    int returnVal;
    Tcl_Interp* interp;
    
    mountCmd = VfsCommand(&interp, "fileattributes", pathPtr);
    if (mountCmd == NULL) {
	return -1;
    }

    Tcl_ListObjAppendElement(interp, mountCmd, Tcl_NewIntObj(index));
    Tcl_SaveResult(interp, &savedResult);
    /* Now we execute this mount point's callback. */
    returnVal = Tcl_EvalObjEx(interp, mountCmd, 
			      TCL_EVAL_GLOBAL | TCL_EVAL_DIRECT);
    if (returnVal != -1) {
	*objPtrRef = Tcl_DuplicateObj(Tcl_GetObjResult(interp));
    }
    Tcl_RestoreResult(interp, &savedResult);
    Tcl_DecrRefCount(mountCmd);
    
    if (returnVal != -1) {
	if (returnVal == TCL_OK) {
	    /* 
	     * Our caller expects a ref count of zero in
	     * the returned object pointer.
	     */
	} else {
	    /* Leave error message in correct interp */
	    Tcl_SetObjResult(cmdInterp, *objPtrRef);
	    *objPtrRef = NULL;
	}
    }
    
    return returnVal;
}

int
VfsFileAttrsSet(cmdInterp, index, pathPtr, objPtr)
    Tcl_Interp *cmdInterp;	/* The interpreter for error reporting. */
    int index;			/* index of the attribute command. */
    Tcl_Obj *pathPtr;		/* filename we are operating on. */
    Tcl_Obj *objPtr;		/* for input. */
{
    Tcl_Obj *mountCmd = NULL;
    Tcl_SavedResult savedResult;
    int returnVal;
    Tcl_Interp* interp;
    Tcl_Obj *errorPtr = NULL;
    
    mountCmd = VfsCommand(&interp, "fileattributes", pathPtr);
    if (mountCmd == NULL) {
	return -1;
    }

    Tcl_ListObjAppendElement(interp, mountCmd, Tcl_NewIntObj(index));
    Tcl_ListObjAppendElement(interp, mountCmd, objPtr);
    Tcl_SaveResult(interp, &savedResult);
    /* Now we execute this mount point's callback. */
    returnVal = Tcl_EvalObjEx(interp, mountCmd, 
			      TCL_EVAL_GLOBAL | TCL_EVAL_DIRECT);
    if (returnVal != -1 && returnVal != TCL_OK) {
	errorPtr = Tcl_DuplicateObj(Tcl_GetObjResult(interp));
    }

    Tcl_RestoreResult(interp, &savedResult);
    Tcl_DecrRefCount(mountCmd);
    
    if (errorPtr != NULL) {
	/* 
	 * Leave error message in correct interp, errorPtr was
	 * duplicated above, in case of threading issues.
	 */
	Tcl_SetObjResult(cmdInterp, errorPtr);
    }
    
    return returnVal;
}

int 
VfsUtime(pathPtr, tval)
    Tcl_Obj* pathPtr;
    struct utimbuf *tval;
{
    Tcl_Obj *mountCmd = NULL;
    Tcl_SavedResult savedResult;
    int returnVal;
    Tcl_Interp* interp;
    
    mountCmd = VfsCommand(&interp, "utime", pathPtr);
    if (mountCmd == NULL) {
	return -1;
    }

    Tcl_ListObjAppendElement(interp, mountCmd, Tcl_NewLongObj(tval->actime));
    Tcl_ListObjAppendElement(interp, mountCmd, Tcl_NewLongObj(tval->modtime));
    /* Now we execute this mount point's callback. */
    Tcl_SaveResult(interp, &savedResult);
    returnVal = Tcl_EvalObjEx(interp, mountCmd, 
			      TCL_EVAL_GLOBAL | TCL_EVAL_DIRECT);
    Tcl_RestoreResult(interp, &savedResult);
    Tcl_DecrRefCount(mountCmd);

    return returnVal;
}

Tcl_Obj*
VfsListVolumes(void)
{
    Tcl_Obj *retVal;

    Tcl_MutexLock(&vfsVolumesMutex);
    if (vfsVolumes != NULL) {
	Tcl_IncrRefCount(vfsVolumes);
	retVal = vfsVolumes;
    } else {
	retVal = NULL;
    }
    Tcl_MutexUnlock(&vfsVolumesMutex);
    
    return retVal;
}

void
Vfs_AddVolume(volume)
    Tcl_Obj *volume;
{
    Tcl_MutexLock(&vfsVolumesMutex);
    
    if (vfsVolumes == NULL) {
        vfsVolumes = Tcl_NewObj();
	Tcl_IncrRefCount(vfsVolumes);
    } else {
	if (Tcl_IsShared(vfsVolumes)) {
	    /* 
	     * Another thread is using this object, so we duplicate the
	     * object and reduce the refCount on the shared one.
	     */
	    Tcl_Obj *oldVols = vfsVolumes;
	    vfsVolumes = Tcl_DuplicateObj(oldVols);
	    Tcl_IncrRefCount(vfsVolumes);
	    Tcl_DecrRefCount(oldVols);
	}
    }
    Tcl_ListObjAppendElement(NULL, vfsVolumes, volume);
    
    Tcl_MutexUnlock(&vfsVolumesMutex);
}

int
Vfs_RemoveVolume(volume)
    Tcl_Obj *volume;
{
    int i, len;

    Tcl_MutexLock(&vfsVolumesMutex);

    Tcl_ListObjLength(NULL, vfsVolumes, &len);
    for (i = 0;i < len; i++) {
	Tcl_Obj *vol;
        Tcl_ListObjIndex(NULL, vfsVolumes, i, &vol);
	if (!strcmp(Tcl_GetString(vol),Tcl_GetString(volume))) {
	    /* It's in the list, at index i */
	    if (len == 1) {
		/* An optimization here */
		Tcl_DecrRefCount(vfsVolumes);
		vfsVolumes = NULL;
	    } else {
		/* Make ourselves the unique owner */
		if (Tcl_IsShared(vfsVolumes)) {
		    Tcl_Obj *oldVols = vfsVolumes;
		    vfsVolumes = Tcl_DuplicateObj(oldVols);
		    Tcl_IncrRefCount(vfsVolumes);
		    Tcl_DecrRefCount(oldVols);
		}
		/* Remove the element */
		Tcl_ListObjReplace(NULL, vfsVolumes, i, 1, 0, NULL);
		Tcl_MutexUnlock(&vfsVolumesMutex);
		return TCL_OK;
	    }
	}
    }
    Tcl_MutexUnlock(&vfsVolumesMutex);

    return TCL_ERROR;
}


/*
 *----------------------------------------------------------------------
 *
 * VfsCommand --
 *
 *	Build a portion of a command to be evaluated in Tcl.  
 *
 * Results:
 *	Returns a list containing the command, or NULL if an
 *	error occurred.
 *
 * Side effects:
 *	None except memory allocation.
 *
 *----------------------------------------------------------------------
 */

static Tcl_Obj* 
VfsCommand(Tcl_Interp **iRef, CONST char* cmd, Tcl_Obj *pathPtr) {
    Tcl_Obj *normed;
    Tcl_Obj *mountCmd;
    int len;
    int splitPosition;
    int dummyLen;
    VfsNativeRep *nativeRep;
    Tcl_Interp *interp;
    
    char *normedString;

    nativeRep = VfsGetNativePath(pathPtr);
    if (nativeRep == NULL) {
	return NULL;
    }
    
    interp = nativeRep->fsCmd->interp;
    
    if (Tcl_InterpDeleted(interp)) {
        return NULL;
    }
    
    splitPosition = nativeRep->splitPosition;
    normed = Tcl_FSGetNormalizedPath(NULL, pathPtr);
    normedString = Tcl_GetStringFromObj(normed, &len);
    
    mountCmd = Tcl_DuplicateObj(nativeRep->fsCmd->mountCmd);
    Tcl_IncrRefCount(mountCmd);
    if (Tcl_ListObjLength(NULL, mountCmd, &dummyLen) == TCL_ERROR) {
	Tcl_DecrRefCount(mountCmd);
	return NULL;
    }
    Tcl_ListObjAppendElement(NULL, mountCmd, Tcl_NewStringObj(cmd,-1));
    if (splitPosition == len) {
	Tcl_ListObjAppendElement(NULL, mountCmd, normed);
	Tcl_ListObjAppendElement(NULL, mountCmd, Tcl_NewStringObj("",0));
    } else {
	Tcl_ListObjAppendElement(NULL, mountCmd, 
		Tcl_NewStringObj(normedString,splitPosition));
	if (normedString[splitPosition] != VFS_SEPARATOR) {
	    /* This will occur if we mount 'ftp://' */
	    splitPosition--;
	}
	Tcl_ListObjAppendElement(NULL, mountCmd, 
		Tcl_NewStringObj(normedString+splitPosition+1,
				 len-splitPosition-1));
    }
    Tcl_ListObjAppendElement(NULL, mountCmd, pathPtr);

    if (iRef != NULL) {
        *iRef = interp;
    }
    
    return mountCmd;
}

static 
void VfsExitProc(ClientData clientData)
{
    Tcl_FSUnregister(&vfsFilesystem);
    /* 
     * This is probably no longer needed, because each individual
     * interp's cleanup will trigger removal of all volumes which
     * belong to it.
     */
    if (vfsVolumes != NULL) {
        Tcl_DecrRefCount(vfsVolumes);
	vfsVolumes = NULL;
    }
}
