/*
import Eco.Kernel.Scheduler exposing (succeed, fail, binding)
import Eco.Kernel.Utils exposing (Tuple2)
import Elm.Kernel.List exposing (toArray)
import Maybe exposing (Just, Nothing)
*/

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
            callback(__Scheduler_fail(e.message));
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
            callback(__Scheduler_fail(e.message));
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
