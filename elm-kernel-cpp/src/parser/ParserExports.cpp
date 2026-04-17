//===- ParserExports.cpp - C-linkage exports for Parser module (STUBS) -----===//
//
// These are stub implementations that will crash if called.
// Full implementation requires proper string indexing and parsing logic.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include <cassert>

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

HPtr Elm_Kernel_Parser_isSubChar(HPtr closure, int64_t offset, HPtr str) {
    (void)closure;
    (void)offset;
    (void)str;
    assert(false && "Elm_Kernel_Parser_isSubChar not implemented");
    return HPtr::fromBits(Export::encodeBoxedBool(false));
}

HPtr Elm_Kernel_Parser_isSubString(HPtr target, int64_t offset, int64_t row, int64_t col, HPtr str) {
    (void)target;
    (void)offset;
    (void)row;
    (void)col;
    (void)str;
    assert(false && "Elm_Kernel_Parser_isSubString not implemented");
    return HPtr::fromBits(Export::encodeBoxedBool(false));
}

int64_t Elm_Kernel_Parser_findSubString(HPtr target, int64_t offset, int64_t row, int64_t col, HPtr str) {
    (void)target;
    (void)offset;
    (void)row;
    (void)col;
    (void)str;
    assert(false && "Elm_Kernel_Parser_findSubString not implemented");
    return -1;
}

HPtr Elm_Kernel_Parser_chompBase10(int64_t offset, HPtr str) {
    (void)offset;
    (void)str;
    assert(false && "Elm_Kernel_Parser_chompBase10 not implemented");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Parser_consumeBase(int64_t base, int64_t offset, HPtr str) {
    (void)base;
    (void)offset;
    (void)str;
    assert(false && "Elm_Kernel_Parser_consumeBase not implemented");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Parser_consumeBase16(int64_t offset, HPtr str) {
    (void)offset;
    (void)str;
    assert(false && "Elm_Kernel_Parser_consumeBase16 not implemented");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_Parser_isAsciiCode(int64_t code, int64_t offset, HPtr str) {
    (void)code;
    (void)offset;
    (void)str;
    assert(false && "Elm_Kernel_Parser_isAsciiCode not implemented");
    return HPtr::fromBits(Export::encodeBoxedBool(false));
}

} // extern "C"
