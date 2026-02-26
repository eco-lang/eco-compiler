/*
import Eco.Kernel.Scheduler exposing (succeed, fail, binding)
*/

var _Process_exit = function(code) {
    return __Scheduler_binding(function(callback) {
        process.exit(code);
    });
};

var _Process_spawn = function(config) {
    return __Scheduler_binding(function(callback) {
        try {
            var child_process = require('child_process');
            var cmd = config.__$cmd;
            var args = config.__$args;
            var opts = {};

            if (config.__$stdin === 'pipe') {
                opts.stdio = ['pipe', 'inherit', 'inherit'];
            } else {
                opts.stdio = ['inherit', 'inherit', 'inherit'];
            }

            var child = child_process.spawn(cmd, args, opts);
            var stdinHandle = child.stdin ? child.pid * 1000 : null;
            callback(__Scheduler_succeed({
                __$stdinHandle: stdinHandle,
                __$ph: child.pid
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
