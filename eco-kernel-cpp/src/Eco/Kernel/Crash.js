/*
*/

// Prints the message with its stack and ends the process with status 1. In a worker thread, where
// process.exit would end only the worker and a supervising runner (elm-test-rs runs tests in workers) would
// wait for it forever, it throws the same error instead, for the runner to report
// (plans/stage1-direct-kernel-linking.md, P4.8).
var _Crash_crash = function(str) {
    Error.stackTraceLimit = Infinity;
    var error = new Error(str);
    if (!_Crash_isMainThread()) {
        throw error;
    }
    console.error(error.stack);
    typeof process !== "undefined" && process.exit(1);
};

// Whether this is the main thread: true outside Node, or where worker_threads cannot be loaded.
function _Crash_isMainThread() {
    try {
        return typeof require !== "function" || require("worker_threads").isMainThread;
    } catch (e) {
        return true;
    }
}
