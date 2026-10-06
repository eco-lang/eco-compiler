//===- HttpExports.cpp - C-linkage exports for Http module ----------------===//

#include "KernelExports.h"
#include "Http.hpp"

using namespace Eco::Kernel;
using Elm::HPtr;

HPtr Eco_Kernel_Http_fetch(HPtr method, HPtr url, HPtr headers) {
    return HPtr::fromBits(Http::fetch(method.toBits(), url.toBits(), headers.toBits()));
}

HPtr Eco_Kernel_Http_getArchive(HPtr url) {
    return HPtr::fromBits(Http::getArchive(url.toBits()));
}
