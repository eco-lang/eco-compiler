/*
import Eco.Kernel.Scheduler exposing (succeed, fail, binding)
import Eco.Kernel.Utils exposing (Tuple2)
import Elm.Kernel.Utils exposing (Tuple3)
import Elm.Kernel.List exposing (toArray)
import Maybe exposing (Just, Nothing)
*/

// Neutral IO error tuple ( classificationTag, path, message ) — see IO_ERR_002.
function _Process_ioErr(e) {
    var codes = { ENOENT: 1, EACCES: 2, EPERM: 2, ENOTDIR: 3, EISDIR: 4,
                  EEXIST: 5, ENOSPC: 6, EMFILE: 7, ENFILE: 7, EPIPE: 8, EBADF: 9 };
    return __Utils_Tuple3(
        (e && codes[e.code]) || 0,
        (e && e.path) ? e.path : '',
        (e && e.message) ? e.message : String(e)
    );
}

var _Process_children = {};
var _Process_streamHandles = {};
var _Process_nextStreamHandle = 10000;

var _Process_exit = function(code) {
    return __Scheduler_binding(function(callback) {
        process.exit(code);
    });
};

var _Process_spawn = F2(function(cmd, args) {
    return __Scheduler_binding(function(callback) {
        try {
            var child_process = require('child_process');
            var child = child_process.spawn(cmd, __List_toArray(args),
                { stdio: ['inherit', 'inherit', 'inherit'] });
            _Process_children[child.pid] = child;
            callback(__Scheduler_succeed(child.pid));
        } catch (e) {
            callback(__Scheduler_fail(_Process_ioErr(e)));
        }
    });
});

var _Process_spawnProcess = F5(function(cmd, args, stdin, stdout, stderr) {
    return __Scheduler_binding(function(callback) {
        try {
            var child_process = require('child_process');
            var child = child_process.spawn(cmd, __List_toArray(args),
                { stdio: [stdin, stdout, stderr] });
            _Process_children[child.pid] = child;
            var stdinHandle;
            if (child.stdin) {
                var handleId = _Process_nextStreamHandle++;
                _Process_streamHandles[handleId] = child.stdin;
                stdinHandle = __Maybe_Just(handleId);
            } else {
                stdinHandle = __Maybe_Nothing;
            }
            callback(__Scheduler_succeed(
                __Utils_Tuple2(stdinHandle, child.pid)
            ));
        } catch (e) {
            callback(__Scheduler_fail(_Process_ioErr(e)));
        }
    });
});

var _Process_wait = function(handle) {
    return __Scheduler_binding(function(callback) {
        var child = _Process_children[handle];
        if (!child) {
            callback(__Scheduler_succeed(0));
            return;
        }
        if (child.exitCode !== null) {
            delete _Process_children[handle];
            callback(__Scheduler_succeed(child.exitCode));
            return;
        }
        child.on('exit', function(code) {
            delete _Process_children[handle];
            callback(__Scheduler_succeed(code || 0));
        });
    });
};
