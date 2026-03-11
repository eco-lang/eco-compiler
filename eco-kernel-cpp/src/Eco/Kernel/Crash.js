/*
*/

var _Crash_crash = function(str) {
    Error.stackTraceLimit = Infinity;
    try {
        throw new Error(str);
    } catch(e) {
        console.error(e.stack);
    }
    typeof process !== "undefined" && process.exit(1);
};
