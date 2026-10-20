//===- SystemExports.cpp - C exports of Eco.Kernel.System -----------------===//
//
// plans/eco-system-library.md Appendix B.1. Exports only pack and bind
// (G2); the bodies are in System.cpp. The effect-manager registration
// (Eco_System_registerManager_System) is in SystemManager.cpp.
//
// Templates used: T1.
//
//===----------------------------------------------------------------------===//

#include "eco-system/System/System.hpp"

using namespace Eco::System;

extern "C" {

// environmentNow : Json.Value -> ( ( String, String, String ), ( List String, Int ), ( Int, Int, Int ) )
// The JSON argument (the flags, ignored) only ties the call to System.environmentDecoder's
// argument (plans/eco-system-api-refactor.md §10.1).
uint64_t Eco_Kernel_System_environmentNow(uint64_t /*json*/) {
    ECO_KERNEL_GUARD(
        return enc(systemEnvironmentNow());
    )
}

// getEnvironmentVariables : Task Never (List ( String, String ))
uint64_t Eco_Kernel_System_getEnvironmentVariables() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<systemGetEnvironmentVariablesBody>(alloc::unit()));
    )
}

// exitWithCode : Int -> Task Never ()
uint64_t Eco_Kernel_System_exitWithCode(int64_t code) {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<systemExitWithCodeBody>(alloc::allocInt(code)));
    )
}

// setExitCode : Int -> Task Never ()
uint64_t Eco_Kernel_System_setExitCode(int64_t code) {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<systemSetExitCodeBody>(alloc::allocInt(code)));
    )
}

// rearmEmptyEventLoop : Task Never ()
uint64_t Eco_Kernel_System_rearmEmptyEventLoop() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<systemRearmEmptyEventLoopBody>(alloc::unit()));
    )
}

} // extern "C"
