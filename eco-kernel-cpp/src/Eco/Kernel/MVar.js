/*
import Eco.Kernel.Scheduler exposing (succeed, fail, binding)
import Elm.Kernel.Utils exposing (Tuple0, Tuple3)
*/

// read, take and put of an id that names no MVar (dropped, or never made) fail with the IO error tuple
// ( 0, "", "MVar not found: <id>" ), as the C++ kernel does (IO_ERR_002); Eco.MVar reads it as an IOError.
function _MVar_notFound(id) {
    return __Scheduler_fail(__Utils_Tuple3(0, '', 'MVar not found: ' + id));
}

var _MVar_nextId = 1;
var _MVar_store = {};

var _MVar_new = __Scheduler_binding(function(callback) {
    var id = _MVar_nextId++;
    _MVar_store[id] = { value: undefined, waiters: [] };
    callback(__Scheduler_succeed(id));
});

var _MVar_read = function(id) {
    return __Scheduler_binding(function(callback) {
        var mvar = _MVar_store[id];
        if (!mvar) {
            callback(_MVar_notFound(id));
            return;
        }
        if (mvar.value !== undefined) {
            callback(__Scheduler_succeed(mvar.value));
        } else {
            mvar.waiters.push({ action: 'read', callback: callback });
        }
    });
};

var _MVar_take = function(id) {
    return __Scheduler_binding(function(callback) {
        var mvar = _MVar_store[id];
        if (!mvar) {
            callback(_MVar_notFound(id));
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

var _MVar_put = F2(function(id, value) {
    return __Scheduler_binding(function(callback) {
        var mvar = _MVar_store[id];
        if (!mvar) {
            callback(_MVar_notFound(id));
            return;
        }
        if (mvar.value === undefined) {
            mvar.value = value;
            _MVar_wakeUp(mvar);
            callback(__Scheduler_succeed(__Utils_Tuple0));
        } else {
            mvar.waiters.push({ action: 'put', value: value, callback: callback });
        }
    });
});

var _MVar_drop = function(id) {
    return __Scheduler_binding(function(callback) {
        delete _MVar_store[id];
        callback(__Scheduler_succeed(__Utils_Tuple0));
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
            w.callback(__Scheduler_succeed(__Utils_Tuple0));
        } else {
            i++;
        }
    }
}
