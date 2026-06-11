//===- NativeDriverExports.cpp - C-linkage exports for NativeDriver -------===//

#include "KernelExports.h"
#include "NativeDriver.hpp"

using namespace Eco::Kernel;
using Elm::HPtr;

HPtr Eco_Kernel_NativeDriver_lowerAndLink(HPtr mlirPath, HPtr outputPath,
                                          HPtr rootModule) {
    return HPtr::fromBits(NativeDriver::lowerAndLink(
        mlirPath.toBits(), outputPath.toBits(), rootModule.toBits()));
}

HPtr Eco_Kernel_NativeDriver_lowerAndLinkBytes(HPtr bytes, HPtr outputPath) {
    return HPtr::fromBits(
        NativeDriver::lowerAndLinkBytes(bytes.toBits(), outputPath.toBits()));
}
