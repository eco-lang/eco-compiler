//===- EffectManagerRegistry.cpp - Central effect manager registration -----===//
//
// Provides a single entry point to register all effect managers with the
// PlatformRuntime. This should be called after the allocator is initialized
// but before any Elm programs run.
//
//===----------------------------------------------------------------------===//

#include "KernelExports.h"

extern "C" {

void eco_register_all_effect_managers() {
    // Register Time effect manager (for Time.every subscriptions)
    eco_register_time_effect_manager();

    // Register Http effect manager (for Http.get/post/request commands)
    eco_register_http_effect_manager();
}

} // extern "C"
