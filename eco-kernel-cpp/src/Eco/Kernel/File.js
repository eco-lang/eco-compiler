/*
import Eco.Kernel.Scheduler exposing (succeed, fail, binding, asyncCallback)
import Elm.Kernel.List exposing (fromArray)
import Elm.Kernel.Utils exposing (Tuple0, Tuple3)
import Maybe exposing (Just, Nothing)
*/

// Normalize a filesystem path to forward slashes so the Elm side (whose
// Utils.Main fp* helpers split/join on "/") never sees backslashes. No-op
// on POSIX. See plans/build-on-windows.md item 10b.
var _File_winNormalize = typeof process !== 'undefined' && process.platform === 'win32';
function _File_normalize(p) {
    return _File_winNormalize && typeof p === 'string' ? p.replace(/\\/g, '/') : p;
}

// Build the neutral IO error tuple ( classificationTag, path, message ) that
// Eco.IO.Error.ofKernelTuple decodes (see IO_ERR_002). Keep the code->tag map in
// sync with Eco.IO.Error.tagFromCode and the C++ kernel.
function _File_ioErr(e) {
    var codes = { ENOENT: 1, EACCES: 2, EPERM: 2, ENOTDIR: 3, EISDIR: 4,
                  EEXIST: 5, ENOSPC: 6, EMFILE: 7, ENFILE: 7, EPIPE: 8, EBADF: 9 };
    return __Utils_Tuple3(
        (e && codes[e.code]) || 0,
        (e && e.path) ? e.path : '',
        (e && e.message) ? e.message : String(e)
    );
}

var _File_readString = function(path) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            var content = fs.readFileSync(path, 'utf8');
            callback(__Scheduler_succeed(content));
        } catch (e) {
            callback(__Scheduler_fail(_File_ioErr(e)));
        }
    });
};

var _File_writeString = F2(function(path, content) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            fs.writeFileSync(path, content, 'utf8');
            callback(__Scheduler_succeed(__Utils_Tuple0));
        } catch (e) {
            callback(__Scheduler_fail(_File_ioErr(e)));
        }
    });
});

var _File_readBytes = function(path) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            var buffer = fs.readFileSync(path);
            callback(__Scheduler_succeed(new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength)));
        } catch (e) {
            callback(__Scheduler_fail(_File_ioErr(e)));
        }
    });
};

var _File_writeBytes = F2(function(path, bytes) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            var buffer = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
            fs.writeFileSync(path, buffer);
            callback(__Scheduler_succeed(__Utils_Tuple0));
        } catch (e) {
            callback(__Scheduler_fail(_File_ioErr(e)));
        }
    });
});

// Temp file + rename: readers never observe a partial file. 'wx' (O_EXCL)
// never shares a temp; pid + sequence make the name unique per call.
var _File_atomicSeq = 0;
var _File_writeBytesAtomic = F2(function(path, bytes) {
    return __Scheduler_binding(function(callback) {
        var fs = require('fs');
        var tmp = path + '.tmp-' + process.pid + '-' + (_File_atomicSeq++);
        try {
            fs.writeFileSync(tmp, Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength), { flag: 'wx' });
            fs.renameSync(tmp, path);
            callback(__Scheduler_succeed(__Utils_Tuple0));
        } catch (e) {
            try { fs.unlinkSync(tmp); } catch (_) {}
            callback(__Scheduler_fail(_File_ioErr(e)));
        }
    });
});

var _File_open = F2(function(path, mode) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            var flags = mode === 0 ? 'r' : mode === 1 ? 'w' : mode === 2 ? 'a' : 'r+';
            var fd = fs.openSync(path, flags);
            callback(__Scheduler_succeed(fd));
        } catch (e) {
            callback(__Scheduler_fail(_File_ioErr(e)));
        }
    });
});

var _File_close = function(handle) {
    return __Scheduler_binding(function(callback) {
        try {
            if (typeof _Process_streamHandles !== 'undefined' && _Process_streamHandles[handle]) {
                _Process_streamHandles[handle].end();
                delete _Process_streamHandles[handle];
            } else {
                var fs = require('fs');
                fs.closeSync(handle);
            }
            callback(__Scheduler_succeed(__Utils_Tuple0));
        } catch (e) {
            callback(__Scheduler_fail(_File_ioErr(e)));
        }
    });
};

var _File_hWriteString = F2(function(handle, content) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            // writeSync may write less than asked; write on until all of it is written, as the C++ kernel does.
            var buf = Buffer.from(content, 'utf8');
            var off = 0;
            while (off < buf.length) {
                off += fs.writeSync(handle, buf, off, buf.length - off);
            }
            callback(__Scheduler_succeed(__Utils_Tuple0));
        } catch (e) {
            callback(__Scheduler_fail(_File_ioErr(e)));
        }
    });
});

var _File_size = function(handle) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            var stat = fs.fstatSync(handle);
            callback(__Scheduler_succeed(stat.size));
        } catch (e) {
            callback(__Scheduler_fail(_File_ioErr(e)));
        }
    });
};

var _File_lock = function(path) {
    return __Scheduler_binding(function(callback) {
        // TODO: implement file locking (e.g., via lockfile or fs-ext)
        callback(__Scheduler_succeed(__Utils_Tuple0));
    });
};

var _File_unlock = function(path) {
    return __Scheduler_binding(function(callback) {
        // TODO: implement file unlocking
        callback(__Scheduler_succeed(__Utils_Tuple0));
    });
};

var _File_fileExists = function(path) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            var stat = fs.statSync(path);
            callback(__Scheduler_succeed(stat.isFile()));
        } catch (e) {
            callback(__Scheduler_succeed(false));
        }
    });
};

var _File_dirExists = function(path) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            var stat = fs.statSync(path);
            callback(__Scheduler_succeed(stat.isDirectory()));
        } catch (e) {
            callback(__Scheduler_succeed(false));
        }
    });
};

var _File_findExecutable = function(name) {
    return __Scheduler_binding(function(callback) {
        var pathEnv = process.env.PATH || process.env.Path || '';
        var sep = process.platform === 'win32' ? ';' : ':';
        var exts = process.platform === 'win32' ? ['.exe', '.cmd', '.bat', '.com', ''] : [''];
        var dirs = pathEnv.split(sep);
        var path = require('path');
        var fs = require('fs');

        // An empty entry (leading, trailing or inner) means the current directory, and a match there is
        // "./name", as POSIX and Haskell's splitSearchPath have it (path.join would drop the "./"). Only a regular
        // file matches: a searchable directory passes the X_OK check too.
        for (var i = 0; i < dirs.length; i++) {
            for (var j = 0; j < exts.length; j++) {
                var fullPath = dirs[i] === '' ? './' + name + exts[j] : path.join(dirs[i], name + exts[j]);
                try {
                    if (!fs.statSync(fullPath).isFile()) continue;
                    fs.accessSync(fullPath, fs.constants.X_OK);
                    callback(__Scheduler_succeed(__Maybe_Just(_File_normalize(fullPath))));
                    return;
                } catch (e) {
                    // continue
                }
            }
        }
        callback(__Scheduler_succeed(__Maybe_Nothing));
    });
};

var _File_list = function(path) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            var entries = fs.readdirSync(path);
            callback(__Scheduler_succeed(__List_fromArray(entries)));
        } catch (e) {
            callback(__Scheduler_fail(_File_ioErr(e)));
        }
    });
};

var _File_modificationTime = function(path) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            var stat = fs.statSync(path);
            // Math.floor preserves full 53-bit epoch millis (~1.78e12). The
            // earlier `| 0` truncated to 32-bit signed int, which broke the
            // registry.dat TTL check in Builder.Deps.Registry.update — every
            // compile re-fetched /all-packages/since.
            callback(__Scheduler_succeed(Math.floor(stat.mtimeMs)));
        } catch (e) {
            callback(__Scheduler_fail(_File_ioErr(e)));
        }
    });
};

var _File_touch = function(path) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            var now = new Date();
            try {
                fs.utimesSync(path, now, now);
            } catch (e) {
                // File doesn't exist — create it, then set times
                fs.closeSync(fs.openSync(path, 'a'));
                fs.utimesSync(path, now, now);
            }
            callback(__Scheduler_succeed(__Utils_Tuple0));
        } catch (e) {
            callback(__Scheduler_fail(_File_ioErr(e)));
        }
    });
};

var _File_getCwd = __Scheduler_binding(function(callback) {
    // process.cwd() throws (ENOENT) once the working directory was removed.
    try {
        callback(__Scheduler_succeed(_File_normalize(process.cwd())));
    } catch (e) {
        callback(__Scheduler_fail(_File_ioErr(e)));
    }
});

var _File_setCwd = function(path) {
    return __Scheduler_binding(function(callback) {
        try {
            process.chdir(path);
            callback(__Scheduler_succeed(__Utils_Tuple0));
        } catch (e) {
            callback(__Scheduler_fail(_File_ioErr(e)));
        }
    });
};

var _File_canonicalize = function(path) {
    return __Scheduler_binding(function(callback) {
        // The empty path fails (ENOENT, as realpath gives), and so does a path that cannot be made absolute
        // (path.resolve throws when the working directory was removed), as in the C++ kernel.
        if (path === '') {
            callback(__Scheduler_fail(_File_ioErr({ code: 'ENOENT', path: '', message: 'could not canonicalize the empty path' })));
            return;
        }
        var resolved;
        try {
            resolved = require('fs').realpathSync(path);
        } catch (e) {
            try {
                resolved = require('path').resolve(path);
            } catch (e2) {
                callback(__Scheduler_fail(_File_ioErr(e2)));
                return;
            }
        }
        callback(__Scheduler_succeed(_File_normalize(resolved)));
    });
};

var _File_appDataDir = function(name) {
    return __Scheduler_binding(function(callback) {
        var os = require('os');
        var path = require('path');
        // os.homedir() returns HOME as it is, even empty; an empty or unset HOME falls back to the passwd entry,
        // as in the C++ kernel. With no home at all the Task fails (ENOENT).
        var home = '';
        try { home = os.homedir(); } catch (e) { home = ''; }
        if (!home && process.platform !== 'win32') {
            try { home = os.userInfo().homedir || ''; } catch (e) { home = ''; }
        }
        if (!home && !(process.platform === 'win32' && process.env.APPDATA)) {
            callback(__Scheduler_fail(_File_ioErr({ code: 'ENOENT', path: '', message: 'cannot find a home directory: set HOME' })));
            return;
        }
        var dir;
        if (process.platform === 'win32') {
            dir = path.join(process.env.APPDATA || home, name);
        } else if (process.platform === 'darwin') {
            dir = path.join(home, 'Library', 'Application Support', name);
        } else {
            dir = path.join(home, '.' + name);
        }
        callback(__Scheduler_succeed(_File_normalize(dir)));
    });
};

var _File_createDir = F2(function(createParents, path) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            fs.mkdirSync(path, { recursive: createParents });
            callback(__Scheduler_succeed(__Utils_Tuple0));
        } catch (e) {
            callback(__Scheduler_fail(_File_ioErr(e)));
        }
    });
});

var _File_removeFile = function(path) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            fs.unlinkSync(path);
            callback(__Scheduler_succeed(__Utils_Tuple0));
        } catch (e) {
            callback(__Scheduler_fail(_File_ioErr(e)));
        }
    });
};

var _File_removeDir = function(path) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            fs.rmSync(path, { recursive: true, force: true });
            callback(__Scheduler_succeed(__Utils_Tuple0));
        } catch (e) {
            callback(__Scheduler_fail(_File_ioErr(e)));
        }
    });
};
