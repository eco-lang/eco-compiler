/*
import Eco.Kernel.Scheduler exposing (binding)
*/

// ChildProcess — JS twin of src/eco-system/ChildProcess/ (eco/system).
// The JS target is not supported yet (plans/eco-system-library.md §1, Phase 10): every
// function throws when called. Zero-argument Task values throw only when the Task runs.

function _ChildProcess_unsupported(name) {
    throw new Error('eco/system: ChildProcess.' + name + ' is not supported on the JS target yet');
}

var _ChildProcess_run = F6(function(a0, a1, a2, a3, a4, a5) { _ChildProcess_unsupported('run'); });
