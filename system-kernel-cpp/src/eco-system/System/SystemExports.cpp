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

// environment : Task Never ( ( String, String, String ), List String, ( Int, Int, Int ) )
uint64_t Eco_Kernel_System_environment() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<systemEnvironmentBody>(alloc::unit()));
    )
}

// getPlatform : Task Never String
uint64_t Eco_Kernel_System_getPlatform() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<systemGetPlatformBody>(alloc::unit()));
    )
}

// getCpuArchitecture : Task Never String
uint64_t Eco_Kernel_System_getCpuArchitecture() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<systemGetCpuArchitectureBody>(alloc::unit()));
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

} // extern "C"
