//===- UtilsExports.cpp - C-linkage exports for Utils module ---------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "Utils.hpp"

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

uint64_t Elm_Kernel_Utils_compare(uint64_t a, uint64_t b) {
    HPointer result = Utils::compare(Export::toPtr(a), Export::toPtr(b));
    return Export::encode(result);
}

int64_t Elm_Kernel_Utils_equal(uint64_t a, uint64_t b) {
    return Export::encodeBool(Utils::equal(Export::toPtr(a), Export::toPtr(b)));
}

int64_t Elm_Kernel_Utils_notEqual(uint64_t a, uint64_t b) {
    return Export::encodeBool(Utils::notEqual(Export::toPtr(a), Export::toPtr(b)));
}

int64_t Elm_Kernel_Utils_lt(uint64_t a, uint64_t b) {
    return Export::encodeBool(Utils::lt(Export::toPtr(a), Export::toPtr(b)));
}

int64_t Elm_Kernel_Utils_le(uint64_t a, uint64_t b) {
    return Export::encodeBool(Utils::le(Export::toPtr(a), Export::toPtr(b)));
}

int64_t Elm_Kernel_Utils_gt(uint64_t a, uint64_t b) {
    return Export::encodeBool(Utils::gt(Export::toPtr(a), Export::toPtr(b)));
}

int64_t Elm_Kernel_Utils_ge(uint64_t a, uint64_t b) {
    return Export::encodeBool(Utils::ge(Export::toPtr(a), Export::toPtr(b)));
}

uint64_t Elm_Kernel_Utils_append(uint64_t a, uint64_t b) {
    HPointer result = Utils::append(Export::toPtr(a), Export::toPtr(b));
    return Export::encode(result);
}

} // extern "C"
