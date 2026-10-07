/*
import Eco.Kernel.Scheduler exposing (binding)
*/

// Terminal — JS twin of src/eco-system/Terminal/ (eco/system).
// The JS target is not supported yet (plans/eco-system-library.md §1, Phase 10): every
// function throws when called. Zero-argument Task values throw only when the Task runs.

function _Terminal_unsupported(name) {
    throw new Error('eco/system: Terminal.' + name + ' is not supported on the JS target yet');
}

var _Terminal_getConfiguration = __Scheduler_binding(function() { _Terminal_unsupported('getConfiguration'); });
var _Terminal_setStdInRawMode = function(a0) { _Terminal_unsupported('setStdInRawMode'); };
var _Terminal_setProcessTitle = function(a0) { _Terminal_unsupported('setProcessTitle'); };
