/*
import Eco.Kernel.Scheduler exposing (succeed, fail, binding)
*/

var _Console_write = function(handle, content) {
    return __Scheduler_binding(function(callback) {
        try {
            if (handle === 1) {
                process.stdout.write(content);
            } else if (handle === 2) {
                process.stderr.write(content);
            }
            callback(__Scheduler_succeed(0 /* Unit */));
        } catch (e) {
            callback(__Scheduler_fail(e.message));
        }
    });
};

var _Console_readLine = __Scheduler_binding(function(callback) {
    var readline = require('readline');
    var rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout,
        terminal: false
    });
    rl.once('line', function(line) {
        rl.close();
        callback(__Scheduler_succeed(line));
    });
    rl.once('close', function() {
        callback(__Scheduler_succeed(''));
    });
});

var _Console_readAll = __Scheduler_binding(function(callback) {
    var chunks = [];
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', function(chunk) {
        chunks.push(chunk);
    });
    process.stdin.on('end', function() {
        callback(__Scheduler_succeed(chunks.join('')));
    });
    process.stdin.resume();
});
