/* 
 * vfs.c --
 *
 *	This file contains the implementation of the Vfs extension
 *	to Tcl.  It provides a script level interface to Tcl's 
 *	virtual file system support, and therefore allows 
 *	vfs's to be implemented in Tcl.
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
 * Structure used for the native representation of a path in a Tcl vfs.
 * To fully specify a file, the string representation is also required.
 */

typedef struct VfsNativeRep {
    int splitPosition;    /* The index into the string representation
                           * of the file which indicates where the 
                           * vfs filesystem is mounted.
                           */
    Tcl_Obj* fsCmd;       /* The Tcl command string which should be
                           * used to perform all filesystem actions
                           * on this file. */
} VfsNativeRep;

/*
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
    /* readlink and listvolumes are not important  */
    NULL,
    NULL,
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
    /* No load, unload */
    NULL,
    NULL,
    /* We don't need a getcwd or chdir */
    NULL,
    NULL
};

/* And some helper procedures */

static VfsNativeRep*     VfsGetNativePath(Tcl_Obj* pathObjPtr);
static Tcl_CloseProc     VfsCloseProc;
static void              VfsExitProc(ClientData clientData);
static Tcl_Obj*          VfsCommand(Tcl_Interp* interp, CONST char* cmd, 
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
    if (Tcl_PkgProvide(interp, "vfs", "1.0") == TCL_ERROR) {
        return TCL_ERROR;
    }

    /*
     * Create additional commands.
     */

    Tcl_CreateObjCommand(interp, "vfs::filesystem", VfsFilesystemObjCmd, 
	    (ClientData) 0, (Tcl_CmdDeleteProc *) NULL);
    /* Register our filesystem */
    Tcl_FSRegister((ClientData)interp, &vfsFilesystem);
    Tcl_CreateExitHandler(VfsExitProc, (ClientData)NULL);

    return TCL_OK;
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
	VFS_INFO, VFS_MOUNT, VFS_UNMOUNT
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
	    Tcl_Obj * path;
	    Tcl_Interp* vfsInterp;
	    if (objc != 4) {
		Tcl_WrongNumArgs(interp, 1, objv, "mount path cmd");
		return TCL_ERROR;
	    }
	    vfsInterp = (Tcl_Interp*) Tcl_FSData(&vfsFilesystem);
	    if (vfsInterp == NULL) {
		Tcl_SetResult(interp, "vfs not registered", TCL_STATIC);
		return TCL_ERROR;
	    }
	    path = Tcl_FSGetNormalizedPath(interp, objv[2]);
	    if (Tcl_SetVar2Ex(vfsInterp, "vfs::mount", 
			      Tcl_GetString(path), objv[3], 
			      TCL_LEAVE_ERR_MSG | TCL_GLOBAL_ONLY) == NULL) {
		return TCL_ERROR;
	    }
	    break;
	}
	case VFS_INFO: {
	    Tcl_Obj * path;
	    Tcl_Interp* vfsInterp;
	    Tcl_Obj * val;
	    if (objc > 3) {
		Tcl_WrongNumArgs(interp, 2, objv, "path");
		return TCL_ERROR;
	    }
	    vfsInterp = (Tcl_Interp*) Tcl_FSData(&vfsFilesystem);
	    if (vfsInterp == NULL) {
		Tcl_SetResult(interp, "vfs not registered", TCL_STATIC);
		return TCL_ERROR;
	    }
	    if (objc == 2) {
		/* List all vfs paths */
		Tcl_GlobalEval(interp, "array names ::vfs::mount");
	    } else {
		path = Tcl_FSGetNormalizedPath(interp, objv[2]);
		val = Tcl_GetVar2Ex(vfsInterp, "vfs::mount", Tcl_GetString(path),
				    TCL_LEAVE_ERR_MSG | TCL_GLOBAL_ONLY);
				  
		if (val == NULL) {
		    return TCL_ERROR;
		}
		Tcl_SetObjResult(interp, val);
	    }
	    break;
	}
	case VFS_UNMOUNT: {
	    Tcl_Obj * path;
	    Tcl_Interp* vfsInterp;
	    int res;
	    if (objc != 3) {
		Tcl_WrongNumArgs(interp, 2, objv, "path");
		return TCL_ERROR;
	    }
	    vfsInterp = (Tcl_Interp*) Tcl_FSData(&vfsFilesystem);
	    if (vfsInterp == NULL) {
		Tcl_SetResult(interp, "vfs not registered", TCL_STATIC);
		return TCL_ERROR;
	    }
	    path = Tcl_FSGetNormalizedPath(interp, objv[2]);
	    res = Tcl_UnsetVar2(vfsInterp, "vfs::mount", Tcl_GetString(path), 
				TCL_LEAVE_ERR_MSG | TCL_GLOBAL_ONLY);
	    return res;
	}
    }
    return TCL_OK;
}

int 
VfsInFilesystem(Tcl_Obj *pathPtr, ClientData *clientDataPtr) {
    Tcl_Obj *normedObj;
    int len, splitPosition;
    char *normed;
    Tcl_Interp* interp;
    VfsNativeRep *nativeRep;
    Tcl_Obj* mountCmd = NULL;
    
    /* 
     * Even Tcl_FSGetNormalizedPath may fail due to lack of system
     * encodings, so we just say we can't handle anything if
     * we are in the middle of the exit sequence.  We could
     * perhaps be more subtle than this!
     */
    if (TclInExit()) {
	return -1;
    }

    interp = (Tcl_Interp*) Tcl_FSData(&vfsFilesystem);
    if (interp == NULL) {
	/* This is bad, but not much we can do about it */
	return -1;
    }

    normedObj = Tcl_FSGetNormalizedPath(interp, pathPtr);
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
    while (mountCmd == NULL) {
	mountCmd = Tcl_GetVar2Ex(interp, "vfs::mount", normed,
				 TCL_GLOBAL_ONLY);
				 
	if (mountCmd != NULL) break;
	if (splitPosition != len) {
	    normed[splitPosition] = VFS_SEPARATOR;
	}
	while ((splitPosition > 0) 
	       && (normed[--splitPosition] != VFS_SEPARATOR)) {
	    /* Do nothing */
	}
	/* Terminate the string there */
	if (splitPosition == 0) {
	    break;
	}
	normed[splitPosition] = 0;
    }
    
    /* 
     * Now either splitPosition is zero, or we found a mount point.
     * Test for both possibilities, just to be sure.
     */
    if ((splitPosition == 0) || (mountCmd == NULL)) {
	return -1;
    }
    if (splitPosition != len) {
	normed[splitPosition] = VFS_SEPARATOR;
    }
    nativeRep = (VfsNativeRep*) ckalloc(sizeof(VfsNativeRep));
    nativeRep->splitPosition = splitPosition;
    nativeRep->fsCmd = mountCmd;
    Tcl_IncrRefCount(nativeRep->fsCmd);
    *clientDataPtr = (ClientData)nativeRep;
    return TCL_OK;
}

/* 
 * Simple helper function to extract the native vfs representation of a
 * path object, or NULL if no such representation exists.
 */
VfsNativeRep* 
VfsGetNativePath(Tcl_Obj* pathObjPtr) {
    return (VfsNativeRep*) Tcl_FSGetInternalRep(pathObjPtr, &vfsFilesystem);
}

void 
VfsFreeInternalRep(ClientData clientData) {
    VfsNativeRep *nativeRep = (VfsNativeRep*)clientData;
    if (nativeRep != NULL) {
	/* Free the command to use on this mount point */
	Tcl_DecrRefCount(nativeRep->fsCmd);
	/* Free the native memory allocation */
	ckfree((char*)nativeRep);
    }
}

ClientData 
VfsDupInternalRep(ClientData clientData) {
    VfsNativeRep *original = (VfsNativeRep*)clientData;

    VfsNativeRep *nativeRep = (VfsNativeRep*) ckalloc(sizeof(VfsNativeRep));
    nativeRep->splitPosition = original->splitPosition;
    nativeRep->fsCmd = original->fsCmd;
    Tcl_IncrRefCount(nativeRep->fsCmd);
    
    return (ClientData)nativeRep;
}

Tcl_Obj* 
VfsFilesystemPathType(Tcl_Obj *pathPtr) {
    VfsNativeRep* nativeRep = VfsGetNativePath(pathPtr);
    if (nativeRep == NULL) {
	return NULL;
    } else {
	return nativeRep->fsCmd;
    }
}

Tcl_Obj*
VfsFilesystemSeparator(Tcl_Obj* pathObjPtr) {
    return Tcl_NewStringObj("/",1);
}

int
VfsStat(pathPtr, bufPtr)
    Tcl_Obj *pathPtr;		/* Path of file to stat (in current CP). */
    struct stat *bufPtr;	/* Filled with results of stat call. */
{
    Tcl_Obj *mountCmd = NULL;
    Tcl_SavedResult savedResult;
    int returnVal;
    Tcl_Interp* interp;
    
    interp = (Tcl_Interp*) Tcl_FSData(&vfsFilesystem);
    mountCmd = VfsCommand(interp, "stat", pathPtr);
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
    
    interp = (Tcl_Interp*) Tcl_FSData(&vfsFilesystem);
    mountCmd = VfsCommand(interp, "access", pathPtr);
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
    
    interp = (Tcl_Interp*) Tcl_FSData(&vfsFilesystem);
    mountCmd = VfsCommand(interp, "open", pathPtr);
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
	        returnVal == TCL_ERROR;
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
    
    interp = (Tcl_Interp*) Tcl_FSData(&vfsFilesystem);
    mountCmd = VfsCommand(interp, "matchindirectory", dirPtr);
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
    
    interp = (Tcl_Interp*) Tcl_FSData(&vfsFilesystem);
    mountCmd = VfsCommand(interp, "deletefile", pathPtr);
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
    
    interp = (Tcl_Interp*) Tcl_FSData(&vfsFilesystem);
    mountCmd = VfsCommand(interp, "createdirectory", pathPtr);
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
    
    interp = (Tcl_Interp*) Tcl_FSData(&vfsFilesystem);
    mountCmd = VfsCommand(interp, "removedirectory", pathPtr);
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
    
    interp = (Tcl_Interp*) Tcl_FSData(&vfsFilesystem);
    mountCmd = VfsCommand(interp, "fileattributes", pathPtr);
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
    
    interp = (Tcl_Interp*) Tcl_FSData(&vfsFilesystem);
    mountCmd = VfsCommand(interp, "fileattributes", pathPtr);
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
    
    interp = (Tcl_Interp*) Tcl_FSData(&vfsFilesystem);
    mountCmd = VfsCommand(interp, "fileattributes", pathPtr);
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
    
    interp = (Tcl_Interp*) Tcl_FSData(&vfsFilesystem);
    mountCmd = VfsCommand(interp, "utime", pathPtr);
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
VfsCommand(Tcl_Interp* interp, CONST char* cmd, Tcl_Obj * pathPtr) {
    Tcl_Obj *normed;
    Tcl_Obj *mountCmd;
    int len;
    int splitPosition;
    int dummyLen;
    VfsNativeRep *nativeRep;
    char *normedString;

    nativeRep = VfsGetNativePath(pathPtr);
    if (nativeRep == NULL) {
	return NULL;
    }
    
    splitPosition = nativeRep->splitPosition;
    normed = Tcl_FSGetNormalizedPath(interp, pathPtr);
    normedString = Tcl_GetStringFromObj(normed, &len);
    
    mountCmd = Tcl_DuplicateObj(nativeRep->fsCmd);
    Tcl_IncrRefCount(mountCmd);
    if (Tcl_ListObjLength(interp, mountCmd, &dummyLen) == TCL_ERROR) {
	Tcl_DecrRefCount(mountCmd);
	return NULL;
    }
    Tcl_ListObjAppendElement(interp, mountCmd, Tcl_NewStringObj(cmd,-1));
    if (splitPosition == len) {
	Tcl_ListObjAppendElement(interp, mountCmd, normed);
	Tcl_ListObjAppendElement(interp, mountCmd, Tcl_NewStringObj("",0));
    } else {
	Tcl_ListObjAppendElement(interp, mountCmd, 
		Tcl_NewStringObj(normedString,splitPosition));
	Tcl_ListObjAppendElement(interp, mountCmd, 
		Tcl_NewStringObj(normedString+splitPosition+1,
				 len-splitPosition-1));
    }
    Tcl_ListObjAppendElement(interp, mountCmd, pathPtr);

    return mountCmd;
}

static 
void VfsExitProc(ClientData clientData)
{
    Tcl_FSUnregister(&vfsFilesystem);
}

