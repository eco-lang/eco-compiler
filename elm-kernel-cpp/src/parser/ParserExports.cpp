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

uint64_t Elm_Kernel_Parser_isSubChar(uint64_t closure, int64_t offset, uint64_t str) {
    (void)closure;
    (void)offset;
    (void)str;
    assert(false && "Elm_Kernel_Parser_isSubChar not implemented");
    return Export::encodeBoxedBool(false);
}

uint64_t Elm_Kernel_Parser_isSubString(uint64_t target, int64_t offset, int64_t row, int64_t col, uint64_t str) {
    (void)target;
    (void)offset;
    (void)row;
    (void)col;
    (void)str;
    assert(false && "Elm_Kernel_Parser_isSubString not implemented");
    return Export::encodeBoxedBool(false);
}

int64_t Elm_Kernel_Parser_findSubString(uint64_t target, int64_t offset, int64_t row, int64_t col, uint64_t str) {
    (void)target;
    (void)offset;
    (void)row;
    (void)col;
    (void)str;
    assert(false && "Elm_Kernel_Parser_findSubString not implemented");
    return -1;
}

uint64_t Elm_Kernel_Parser_chompBase10(int64_t offset, uint64_t str) {
    (void)offset;
    (void)str;
    assert(false && "Elm_Kernel_Parser_chompBase10 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Parser_consumeBase(int64_t base, int64_t offset, uint64_t str) {
    (void)base;
    (void)offset;
    (void)str;
    assert(false && "Elm_Kernel_Parser_consumeBase not implemented");
    return 0;
}

uint64_t Elm_Kernel_Parser_consumeBase16(int64_t offset, uint64_t str) {
    (void)offset;
    (void)str;
    assert(false && "Elm_Kernel_Parser_consumeBase16 not implemented");
    return 0;
}

uint64_t Elm_Kernel_Parser_isAsciiCode(int64_t code, int64_t offset, uint64_t str) {
    (void)code;
    (void)offset;
    (void)str;
    assert(false && "Elm_Kernel_Parser_isAsciiCode not implemented");
    return Export::encodeBoxedBool(false);
}

} // extern "C"
