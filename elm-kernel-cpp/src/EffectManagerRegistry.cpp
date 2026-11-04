//===- EffectManagerRegistry.cpp - Central effect manager registration -----===//
//
// Each registrar allocates its manager's closures on the calling thread's GC
// heap. When `eco_register_all_effect_managers` must run is stated on its
// declaration in `KernelExports.h`.
//
//===----------------------------------------------------------------------===//

#include "KernelExports.h"

extern "C" {

void eco_register_all_effect_managers() {
    // Register Time effect manager (for Time.every subscriptions)
    eco_register_time_effect_manager();

    // Register Http effect manager (Http commands and subscriptions)
    eco_register_http_effect_manager();

    // Register Task effect manager (for Task.perform/attempt commands)
    eco_register_task_effect_manager();
}

} // extern "C"
