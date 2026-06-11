/*
import Eco.Kernel.Scheduler exposing (binding, succeed, fail)
import Elm.Kernel.Utils exposing (Tuple0)
*/

// NativeDriver kernel: only meaningful when running inside the unified `eco`
// native binary (where EcoNativeDriverStatic provides the strong
// `eco_native_lower_and_link` symbol). The JS bootstrap stages (1–5) never
// reach `handleElfOutput`, so these stubs only exist so the kernel module
// compiles into eco-boot.js / eco-boot-2.js. Calling them is a programming
// error and surfaces as a Task failure.

var _NativeDriver_lowerAndLink = F3(function (mlirPath, outputPath, rootModule) {
    return __Scheduler_binding(function (callback) {
        callback(__Scheduler_fail(
            'Eco.NativeDriver.lowerAndLink is not available in the JS bootstrap'));
    });
});

var _NativeDriver_lowerAndLinkBytes = F2(function (bytes, outputPath) {
    return __Scheduler_binding(function (callback) {
        callback(__Scheduler_fail(
            'Eco.NativeDriver.lowerAndLinkBytes is not available in the JS bootstrap'));
    });
});
