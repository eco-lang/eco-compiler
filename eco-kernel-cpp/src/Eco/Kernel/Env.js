/*
import Eco.Kernel.Scheduler exposing (succeed, binding)
import Maybe exposing (Just, Nothing)
*/

var _Env_lookup = function(name) {
    return __Scheduler_binding(function(callback) {
        var value = process.env[name];
        if (value !== undefined) {
            callback(__Scheduler_succeed(__Maybe_Just(value)));
        } else {
            callback(__Scheduler_succeed(__Maybe_Nothing));
        }
    });
};

var _Env_rawArgs = __Scheduler_binding(function(callback) {
    callback(__Scheduler_succeed(process.argv.slice(2)));
});
