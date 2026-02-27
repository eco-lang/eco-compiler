//===- ProcessExports.cpp - C-linkage exports for Process module ----------===//

#include "KernelExports.h"
#include "Process.hpp"

using namespace Eco::Kernel;

uint64_t Eco_Kernel_Process_exit(int64_t code) {
    return Process::exit(code);
}

uint64_t Eco_Kernel_Process_spawn(uint64_t cmd, uint64_t args) {
    return Process::spawn(cmd, args);
}

uint64_t Eco_Kernel_Process_spawnProcess(uint64_t cmd, uint64_t args, uint64_t stdin_, uint64_t stdout_, uint64_t stderr_) {
    return Process::spawnProcess(cmd, args, stdin_, stdout_, stderr_);
}

uint64_t Eco_Kernel_Process_wait(uint64_t handle) {
    return Process::wait(handle);
}
