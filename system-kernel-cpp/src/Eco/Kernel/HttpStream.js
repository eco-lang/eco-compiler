/*
import Eco.Kernel.Scheduler exposing (binding)
*/

// HttpStream — JS twin of src/eco-system/HttpStream/ (eco/system).
// The JS target is not supported yet (plans/eco-system-library.md §1, Phase 10): every
// function throws when called. Zero-argument Task values throw only when the Task runs.

function _HttpStream_unsupported(name) {
    throw new Error('eco/system: HttpStream.' + name + ' is not supported on the JS target yet');
}

var _HttpStream_send = F4(function(a0, a1, a2, a3) { _HttpStream_unsupported('send'); });
