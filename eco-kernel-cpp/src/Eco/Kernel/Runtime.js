/*
import Eco.Kernel.Scheduler exposing (succeed, binding)
import Elm.Kernel.Utils exposing (Tuple0)
*/

var _Runtime_dirname = __Scheduler_binding(function(callback) {
    // The directory of this bundle, i.e. Node's per-module dirname global.
    // That global cannot be named here: the kernel-JS parser reads every
    // identifier starting with a double underscore as a kernel tag, and
    // --optimize then mangled it to an undefined field name (ReferenceError
    // in the bootstrap). The bundle is loaded with require(), so CommonJS's
    // `module` is in scope.
    var dir = typeof module !== 'undefined' && module.filename
        ? require('path').dirname(module.filename)
        : process.cwd();
    // Normalize to forward slashes for the Elm fp* helpers — see
    // plans/build-on-windows.md item 10b and _File_normalize in File.js.
    var d = typeof process !== 'undefined' && process.platform === 'win32'
        ? dir.replace(/\\/g, '/')
        : dir;
    callback(__Scheduler_succeed(d));
});

var _Runtime_random = __Scheduler_binding(function(callback) {
    callback(__Scheduler_succeed(Math.random()));
});

var _Runtime_replState = null;

var _Runtime_saveState = function(state) {
    return __Scheduler_binding(function(callback) {
        _Runtime_replState = state;
        callback(__Scheduler_succeed(__Utils_Tuple0));
    });
};

var _Runtime_loadState = __Scheduler_binding(function(callback) {
    callback(__Scheduler_succeed(_Runtime_replState));
});
