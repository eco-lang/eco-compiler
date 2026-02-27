//===- HttpExports.cpp - C-linkage exports for Http module ----------------===//

#include "KernelExports.h"
#include "Http.hpp"

using namespace Eco::Kernel;

uint64_t Eco_Kernel_Http_fetch(uint64_t method, uint64_t url, uint64_t headers) {
    return Http::fetch(method, url, headers);
}

uint64_t Eco_Kernel_Http_getArchive(uint64_t url) {
    return Http::getArchive(url);
}
