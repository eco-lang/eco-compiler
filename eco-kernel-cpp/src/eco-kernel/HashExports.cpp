//===- HashExports.cpp - C-linkage exports for Hash ----------------------===//

#include "KernelExports.h"
#include "ExportHelpers.hpp"
#include "Hash.hpp"

using namespace Eco::Kernel;
using Elm::HPtr;

int64_t Eco_Kernel_Hash_stringWithSeed(int64_t seed, HPtr str) {
    return Hash::stringWithSeed(Export::toPtr(str.toBits()), seed);
}

int64_t Eco_Kernel_Hash_string64(int64_t seed, HPtr str) {
    return Hash::string64(Export::toPtr(str.toBits()), seed);
}
