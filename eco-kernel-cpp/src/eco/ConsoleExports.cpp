//===- ConsoleExports.cpp - C-linkage exports for Console module ----------===//

#include "KernelExports.h"
#include "Console.hpp"

using namespace Eco::Kernel;

uint64_t Eco_Kernel_Console_write(uint64_t handle, uint64_t content) {
    return Console::write(handle, content);
}

uint64_t Eco_Kernel_Console_readLine() {
    return Console::readLine();
}

uint64_t Eco_Kernel_Console_readAll() {
    return Console::readAll();
}
