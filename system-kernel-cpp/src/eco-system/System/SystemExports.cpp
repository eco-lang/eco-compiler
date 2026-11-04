//===- SystemExports.cpp - C exports of Eco.Kernel.System -----------------===//
//
// The C-linkage kernels of Eco.Kernel.System, called by compiled Elm code. Each one only packs its
// argument and binds a body from System.hpp into a Task, except `environmentNow`, which returns its value
// directly. A C++ exception escaping an export is a fatal error (`ECO_KERNEL_GUARD`). The effect manager's
// registration is in SystemManager.cpp.
//
//===----------------------------------------------------------------------===//

#include "eco-system/System/System.hpp"

using namespace Eco::System;

extern "C" {

// environmentNow : Json.Value -> ( ( String, String, String ), ( List String, Int ), ( Int, Int, Int ) )
// Returns `systemEnvironmentNow()` at once, not a Task. The JSON argument is ignored.
uint64_t Eco_Kernel_System_environmentNow(uint64_t /*json*/) {
    ECO_KERNEL_GUARD(
        return enc(systemEnvironmentNow());
    )
}

// getEnvironmentVariables : Task Never (List ( String, String ))
// Returns a Task that reads the environment variables each time it runs.
uint64_t Eco_Kernel_System_getEnvironmentVariables() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<systemGetEnvironmentVariablesBody>(alloc::unit()));
    )
}

// exitWithCode : Int -> Task Never ()
// Returns a Task that sets the exit code to `code` and ends the program when it runs.
uint64_t Eco_Kernel_System_exitWithCode(int64_t code) {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<systemExitWithCodeBody>(alloc::allocInt(code)));
    )
}

// setExitCode : Int -> Task Never ()
// Returns a Task that sets the exit code to `code` when it runs.
uint64_t Eco_Kernel_System_setExitCode(int64_t code) {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<systemSetExitCodeBody>(alloc::allocInt(code)));
    )
}

// rearmEmptyEventLoop : Task Never ()
// Returns a Task that arms the empty-event-loop subscription again when it runs.
uint64_t Eco_Kernel_System_rearmEmptyEventLoop() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<systemRearmEmptyEventLoopBody>(alloc::unit()));
    )
}

} // extern "C"
