/*
import Eco.Kernel.Scheduler exposing (succeed, binding)
*/

var _MVar_nextId = 1;
var _MVar_store = {};

var _MVar_new = __Scheduler_binding(function(callback) {
    var id = _MVar_nextId++;
    _MVar_store[id] = { value: undefined, waiters: [] };
    callback(__Scheduler_succeed(id));
});

var _MVar_read = function(typeTag, id) {
    return __Scheduler_binding(function(callback) {
        var mvar = _MVar_store[id];
        if (!mvar) {
            callback(__Scheduler_succeed(undefined));
            return;
        }
        if (mvar.value !== undefined) {
            callback(__Scheduler_succeed(mvar.value));
        } else {
            mvar.waiters.push({ action: 'read', callback: callback });
        }
    });
};

var _MVar_take = function(typeTag, id) {
    return __Scheduler_binding(function(callback) {
        var mvar = _MVar_store[id];
        if (!mvar) {
            callback(__Scheduler_succeed(undefined));
            return;
        }
        if (mvar.value !== undefined) {
            var value = mvar.value;
            mvar.value = undefined;
            _MVar_wakeUp(mvar);
            callback(__Scheduler_succeed(value));
        } else {
            mvar.waiters.push({ action: 'take', callback: callback });
        }
    });
};

var _MVar_put = function(typeTag, id, value) {
    return __Scheduler_binding(function(callback) {
        var mvar = _MVar_store[id];
        if (!mvar) {
            callback(__Scheduler_succeed(0 /* Unit */));
            return;
        }
        if (mvar.value === undefined) {
            mvar.value = value;
            _MVar_wakeUp(mvar);
            callback(__Scheduler_succeed(0 /* Unit */));
        } else {
            mvar.waiters.push({ action: 'put', value: value, callback: callback });
        }
    });
};

function _MVar_wakeUp(mvar) {
    var i = 0;
    while (i < mvar.waiters.length) {
        var w = mvar.waiters[i];
        if (w.action === 'read' && mvar.value !== undefined) {
            mvar.waiters.splice(i, 1);
            w.callback(__Scheduler_succeed(mvar.value));
        } else if (w.action === 'take' && mvar.value !== undefined) {
            mvar.waiters.splice(i, 1);
            var val = mvar.value;
            mvar.value = undefined;
            w.callback(__Scheduler_succeed(val));
        } else if (w.action === 'put' && mvar.value === undefined) {
            mvar.waiters.splice(i, 1);
            mvar.value = w.value;
            w.callback(__Scheduler_succeed(0 /* Unit */));
        } else {
            i++;
        }
    }
}
