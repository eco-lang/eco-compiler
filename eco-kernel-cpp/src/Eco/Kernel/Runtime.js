/*
import Eco.Kernel.Scheduler exposing (succeed, binding)
*/

var _Runtime_dirname = __Scheduler_binding(function(callback) {
    callback(__Scheduler_succeed(__dirname));
});

var _Runtime_random = __Scheduler_binding(function(callback) {
    callback(__Scheduler_succeed(Math.random()));
});

var _Runtime_replState = null;

var _Runtime_saveState = function(state) {
    return __Scheduler_binding(function(callback) {
        _Runtime_replState = state;
        callback(__Scheduler_succeed(0 /* Unit */));
    });
};

var _Runtime_loadState = __Scheduler_binding(function(callback) {
    callback(__Scheduler_succeed(_Runtime_replState));
});
