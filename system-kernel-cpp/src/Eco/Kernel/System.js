/*
import Eco.Kernel.Scheduler exposing (binding)
*/

// System — JS twin of src/eco-system/System/ (eco/system).
// The JS target is not supported yet (plans/eco-system-library.md §1, Phase 10): every
// function throws when called. Zero-argument Task values throw only when the Task runs.

function _System_unsupported(name) {
    throw new Error('eco/system: System.' + name + ' is not supported on the JS target yet');
}

var _System_environment = __Scheduler_binding(function() { _System_unsupported('environment'); });
var _System_getPlatform = __Scheduler_binding(function() { _System_unsupported('getPlatform'); });
var _System_getCpuArchitecture = __Scheduler_binding(function() { _System_unsupported('getCpuArchitecture'); });
var _System_getEnvironmentVariables = __Scheduler_binding(function() { _System_unsupported('getEnvironmentVariables'); });
var _System_exitWithCode = function(a0) { _System_unsupported('exitWithCode'); };
var _System_setExitCode = function(a0) { _System_unsupported('setExitCode'); };
