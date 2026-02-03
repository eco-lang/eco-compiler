//===- RegexExports.cpp - C-linkage exports for Regex module (STUBS) -------===//
//
// These are stub implementations that will crash if called.
// Full implementation requires a regex engine (e.g., std::regex or RE2).
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include <cassert>
#include <cmath>

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

uint64_t Elm_Kernel_Regex_never() {
    // Return a regex that never matches anything.
    // This is used as the "empty" regex.
    assert(false && "Elm_Kernel_Regex_never not implemented");
    return 0;
}

double Elm_Kernel_Regex_infinity() {
    // Return positive infinity (used for "match all" in replaceAtMost, etc.).
    return std::numeric_limits<double>::infinity();
}

uint64_t Elm_Kernel_Regex_fromStringWith(uint64_t options, uint64_t pattern) {
    (void)options;
    (void)pattern;
    assert(false && "Elm_Kernel_Regex_fromStringWith not implemented");
    return 0;
}

uint64_t Elm_Kernel_Regex_contains(uint64_t regex, uint64_t str) {
    (void)regex;
    (void)str;
    assert(false && "Elm_Kernel_Regex_contains not implemented");
    return Export::encodeBoxedBool(false);
}

uint64_t Elm_Kernel_Regex_findAtMost(int64_t n, uint64_t regex, uint64_t str) {
    (void)n;
    (void)regex;
    (void)str;
    assert(false && "Elm_Kernel_Regex_findAtMost not implemented");
    return 0;
}

uint64_t Elm_Kernel_Regex_replaceAtMost(int64_t n, uint64_t regex, uint64_t closure, uint64_t str) {
    (void)n;
    (void)regex;
    (void)closure;
    (void)str;
    assert(false && "Elm_Kernel_Regex_replaceAtMost not implemented");
    return 0;
}

uint64_t Elm_Kernel_Regex_splitAtMost(int64_t n, uint64_t regex, uint64_t str) {
    (void)n;
    (void)regex;
    (void)str;
    assert(false && "Elm_Kernel_Regex_splitAtMost not implemented");
    return 0;
}

} // extern "C"
