//===- ProcessExports.cpp - C-linkage exports for Process module ----------===//

#include "KernelExports.h"
#include "Process.hpp"

using namespace Eco::Kernel;

uint64_t Eco_Kernel_Process_exit(uint64_t code) {
    return Process::exit(code);
}

uint64_t Eco_Kernel_Process_spawn(uint64_t config) {
    return Process::spawn(config);
}

uint64_t Eco_Kernel_Process_wait(uint64_t handle) {
    return Process::wait(handle);
}
