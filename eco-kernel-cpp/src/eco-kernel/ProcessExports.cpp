//===- ProcessExports.cpp - C-linkage exports for Process module ----------===//

#include "KernelExports.h"
#include "Process.hpp"

using namespace Eco::Kernel;
using Elm::HPtr;

HPtr Eco_Kernel_Process_exit(int64_t code) {
    ECO_KERNEL_GUARD( return HPtr::fromBits(Process::exit(code)); )
}

uint64_t Eco_Kernel_Process_spawn(HPtr cmd, HPtr args) {
    ECO_KERNEL_GUARD( return Process::spawn(cmd.toBits(), args.toBits()); )
}

HPtr Eco_Kernel_Process_spawnProcess(HPtr cmd, HPtr args, HPtr stdin_) {
    ECO_KERNEL_GUARD( return HPtr::fromBits(Process::spawnProcess(cmd.toBits(), args.toBits(), stdin_.toBits())); )
}

uint64_t Eco_Kernel_Process_wait(HPtr handle) {
    ECO_KERNEL_GUARD( return Process::wait(handle.toBits()); )
}
