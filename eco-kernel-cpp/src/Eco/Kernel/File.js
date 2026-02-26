/*
import Eco.Kernel.Scheduler exposing (succeed, fail, binding, asyncCallback)
import Maybe exposing (Just, Nothing)
*/

var _File_readString = function(path) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            var content = fs.readFileSync(path, 'utf8');
            callback(__Scheduler_succeed(content));
        } catch (e) {
            callback(__Scheduler_fail(e.message));
        }
    });
};

var _File_writeString = function(path, content) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            fs.writeFileSync(path, content, 'utf8');
            callback(__Scheduler_succeed(0 /* Unit */));
        } catch (e) {
            callback(__Scheduler_fail(e.message));
        }
    });
};

var _File_readBytes = function(path) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            var buffer = fs.readFileSync(path);
            callback(__Scheduler_succeed(new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength)));
        } catch (e) {
            callback(__Scheduler_fail(e.message));
        }
    });
};

var _File_writeBytes = function(path, bytes) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            var buffer = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
            fs.writeFileSync(path, buffer);
            callback(__Scheduler_succeed(0 /* Unit */));
        } catch (e) {
            callback(__Scheduler_fail(e.message));
        }
    });
};

var _File_open = function(path, mode) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            var flags = mode === 0 ? 'r' : mode === 1 ? 'w' : mode === 2 ? 'a' : 'r+';
            var fd = fs.openSync(path, flags);
            callback(__Scheduler_succeed(fd));
        } catch (e) {
            callback(__Scheduler_fail(e.message));
        }
    });
};

var _File_close = function(handle) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            fs.closeSync(handle);
            callback(__Scheduler_succeed(0 /* Unit */));
        } catch (e) {
            callback(__Scheduler_fail(e.message));
        }
    });
};

var _File_size = function(handle) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            var stat = fs.fstatSync(handle);
            callback(__Scheduler_succeed(stat.size));
        } catch (e) {
            callback(__Scheduler_fail(e.message));
        }
    });
};

var _File_lock = function(path) {
    return __Scheduler_binding(function(callback) {
        // TODO: implement file locking (e.g., via lockfile or fs-ext)
        callback(__Scheduler_succeed(0 /* Unit */));
    });
};

var _File_unlock = function(path) {
    return __Scheduler_binding(function(callback) {
        // TODO: implement file unlocking
        callback(__Scheduler_succeed(0 /* Unit */));
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

        for (var i = 0; i < dirs.length; i++) {
            for (var j = 0; j < exts.length; j++) {
                var fullPath = path.join(dirs[i], name + exts[j]);
                try {
                    fs.accessSync(fullPath, fs.constants.X_OK);
                    callback(__Scheduler_succeed(__Maybe_Just(fullPath)));
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
            callback(__Scheduler_succeed(entries));
        } catch (e) {
            callback(__Scheduler_fail(e.message));
        }
    });
};

var _File_modificationTime = function(path) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            var stat = fs.statSync(path);
            callback(__Scheduler_succeed(stat.mtimeMs | 0));
        } catch (e) {
            callback(__Scheduler_fail(e.message));
        }
    });
};

var _File_getCwd = __Scheduler_binding(function(callback) {
    callback(__Scheduler_succeed(process.cwd()));
});

var _File_setCwd = function(path) {
    return __Scheduler_binding(function(callback) {
        try {
            process.chdir(path);
            callback(__Scheduler_succeed(0 /* Unit */));
        } catch (e) {
            callback(__Scheduler_fail(e.message));
        }
    });
};

var _File_canonicalize = function(path) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            var resolved = fs.realpathSync(path);
            callback(__Scheduler_succeed(resolved));
        } catch (e) {
            callback(__Scheduler_fail(e.message));
        }
    });
};

var _File_appDataDir = function(name) {
    return __Scheduler_binding(function(callback) {
        var os = require('os');
        var path = require('path');
        var home = os.homedir();
        var dir;
        if (process.platform === 'win32') {
            dir = path.join(process.env.APPDATA || home, name);
        } else if (process.platform === 'darwin') {
            dir = path.join(home, 'Library', 'Application Support', name);
        } else {
            dir = path.join(home, '.' + name);
        }
        callback(__Scheduler_succeed(dir));
    });
};

var _File_createDir = function(createParents, path) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            fs.mkdirSync(path, { recursive: createParents });
            callback(__Scheduler_succeed(0 /* Unit */));
        } catch (e) {
            callback(__Scheduler_fail(e.message));
        }
    });
};

var _File_removeFile = function(path) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            fs.unlinkSync(path);
            callback(__Scheduler_succeed(0 /* Unit */));
        } catch (e) {
            callback(__Scheduler_fail(e.message));
        }
    });
};

var _File_removeDir = function(path) {
    return __Scheduler_binding(function(callback) {
        try {
            var fs = require('fs');
            fs.rmSync(path, { recursive: true, force: true });
            callback(__Scheduler_succeed(0 /* Unit */));
        } catch (e) {
            callback(__Scheduler_fail(e.message));
        }
    });
};
