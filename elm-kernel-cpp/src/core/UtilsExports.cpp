//===- UtilsExports.cpp - C-linkage exports for Utils module ---------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "Utils.hpp"
#include <cstdio>

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

uint64_t Elm_Kernel_Utils_compare(uint64_t a, uint64_t b) {
    HPointer result = Utils::compare(Export::toPtr(a), Export::toPtr(b));
    return Export::encode(result);
}

uint64_t Elm_Kernel_Utils_equal(uint64_t a, uint64_t b) {
    return Export::encodeBoxedBool(Utils::equal(Export::toPtr(a), Export::toPtr(b)));
}

uint64_t Elm_Kernel_Utils_notEqual(uint64_t a, uint64_t b) {
    return Export::encodeBoxedBool(Utils::notEqual(Export::toPtr(a), Export::toPtr(b)));
}

uint64_t Elm_Kernel_Utils_lt(uint64_t a, uint64_t b) {
    return Export::encodeBoxedBool(Utils::lt(Export::toPtr(a), Export::toPtr(b)));
}

uint64_t Elm_Kernel_Utils_le(uint64_t a, uint64_t b) {
    return Export::encodeBoxedBool(Utils::le(Export::toPtr(a), Export::toPtr(b)));
}

uint64_t Elm_Kernel_Utils_gt(uint64_t a, uint64_t b) {
    return Export::encodeBoxedBool(Utils::gt(Export::toPtr(a), Export::toPtr(b)));
}

uint64_t Elm_Kernel_Utils_ge(uint64_t a, uint64_t b) {
    return Export::encodeBoxedBool(Utils::ge(Export::toPtr(a), Export::toPtr(b)));
}

uint64_t Elm_Kernel_Utils_append(uint64_t a, uint64_t b) {
    void* ptrA = Export::toPtr(a);
    void* ptrB = Export::toPtr(b);
    // Both are embedded constants (e.g. "" ++ "" or [] ++ []).
    // toPtr returns nullptr for embedded constants, so return either one directly.
    if (!ptrA && !ptrB) return a;
    HPointer result = Utils::append(ptrA, ptrB);
    return Export::encode(result);
}

} // extern "C"
