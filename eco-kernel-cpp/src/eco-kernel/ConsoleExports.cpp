//===- ConsoleExports.cpp - C-linkage exports for Console module ----------===//

#include "KernelExports.h"
#include "Console.hpp"

using namespace Eco::Kernel;
using Elm::HPtr;

HPtr Eco_Kernel_Console_write(HPtr handle, HPtr content) {
    ECO_KERNEL_GUARD( return HPtr::fromBits(Console::write(handle.toBits(), content.toBits())); )
}

HPtr Eco_Kernel_Console_readLine() {
    ECO_KERNEL_GUARD( return HPtr::fromBits(Console::readLine()); )
}

HPtr Eco_Kernel_Console_readAll() {
    ECO_KERNEL_GUARD( return HPtr::fromBits(Console::readAll()); )
}

HPtr Eco_Kernel_Console_log(HPtr tag, HPtr value) {
    ECO_KERNEL_GUARD( return HPtr::fromBits(Console::log(tag.toBits(), value.toBits())); )
}
