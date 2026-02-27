/*
import Eco.Kernel.Scheduler exposing (succeed, fail, binding)
import Maybe exposing (Just, Nothing)
*/

var _Process_exit = function(code) {
    return __Scheduler_binding(function(callback) {
        process.exit(code);
    });
};

var _Process_spawn = function(cmd, args) {
    return __Scheduler_binding(function(callback) {
        try {
            var child_process = require('child_process');
            var child = child_process.spawn(cmd, _List_toArray(args),
                { stdio: ['inherit', 'inherit', 'inherit'] });
            callback(__Scheduler_succeed(child.pid));
        } catch (e) {
            callback(__Scheduler_fail(e.message));
        }
    });
};

var _Process_spawnProcess = function(cmd, args, stdin, stdout, stderr) {
    return __Scheduler_binding(function(callback) {
        try {
            var child_process = require('child_process');
            var child = child_process.spawn(cmd, _List_toArray(args),
                { stdio: [stdin, stdout, stderr] });
            var stdinHandle = child.stdin ? __Maybe_Just(child.pid * 1000) : __Maybe_Nothing;
            callback(__Scheduler_succeed({
                stdinHandle: stdinHandle,
                processHandle: child.pid
            }));
        } catch (e) {
            callback(__Scheduler_fail(e.message));
        }
    });
};

var _Process_wait = function(handle) {
    return __Scheduler_binding(function(callback) {
        // TODO: track spawned processes and wait for exit
        callback(__Scheduler_succeed(0));
    });
};
