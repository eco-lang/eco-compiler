/*
import Eco.Kernel.Scheduler exposing (succeed, fail, binding)
import Elm.Kernel.Utils exposing (Tuple0, Tuple3)
*/

// Neutral IO error tuple ( classificationTag, path, message ) — see IO_ERR_002.
function _Console_ioErr(e) {
    var codes = { ENOENT: 1, EACCES: 2, EPERM: 2, ENOTDIR: 3, EISDIR: 4,
                  EEXIST: 5, ENOSPC: 6, EMFILE: 7, ENFILE: 7, EPIPE: 8, EBADF: 9 };
    return __Utils_Tuple3(
        (e && codes[e.code]) || 0,
        (e && e.path) ? e.path : '',
        (e && e.message) ? e.message : String(e)
    );
}

var _Console_write = F2(function(handle, content) {
    return __Scheduler_binding(function(callback) {
        try {
            if (handle === 1) {
                process.stdout.write(content);
            } else if (handle === 2) {
                process.stderr.write(content);
            } else if (typeof _Process_streamHandles !== 'undefined' && _Process_streamHandles[handle]) {
                _Process_streamHandles[handle].write(content);
            }
            callback(__Scheduler_succeed(__Utils_Tuple0));
        } catch (e) {
            callback(__Scheduler_fail(_Console_ioErr(e)));
        }
    });
});

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

// Eco.Console.log : String -> a -> a
// Pure side-effect: writes `tag` (with newline) to stderr and returns `value`
// unchanged. Mirrors Debug.log's pattern but is allowed under --optimize.
var _Console_log = F2(function(tag, value) {
    try {
        process.stderr.write(tag + '\n');
    } catch (e) {
        // Best-effort: never crash from a trace point.
    }
    return value;
});
