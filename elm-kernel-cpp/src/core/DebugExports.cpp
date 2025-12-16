//===- DebugExports.cpp - C-linkage exports for Debug module ---------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "Debug.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"

using namespace Elm;
using namespace Elm::Kernel;

namespace {

// Convert ElmString to std::string (UTF-16 to UTF-8)
std::string elmStringToStd(void* ptr) {
    if (!ptr) return "";
    ElmString* s = static_cast<ElmString*>(ptr);
    std::string result;
    result.reserve(s->header.size);
    for (u32 i = 0; i < s->header.size; i++) {
        u16 c = s->chars[i];
        if (c < 0x80) {
            result.push_back(static_cast<char>(c));
        } else if (c < 0x800) {
            result.push_back(static_cast<char>(0xC0 | (c >> 6)));
            result.push_back(static_cast<char>(0x80 | (c & 0x3F)));
        } else {
            result.push_back(static_cast<char>(0xE0 | (c >> 12)));
            result.push_back(static_cast<char>(0x80 | ((c >> 6) & 0x3F)));
            result.push_back(static_cast<char>(0x80 | (c & 0x3F)));
        }
    }
    return result;
}

} // anonymous namespace

extern "C" {

uint64_t Elm_Kernel_Debug_log(uint64_t tag, uint64_t value) {
    // log prints the tag and value, then returns the value unchanged
    std::string tagStr = elmStringToStd(Export::toPtr(tag));
    // For now, just print the tag (stub implementation)
    // The actual Debug.log would print both tag and value
    fprintf(stderr, "[%s] <value>\n", tagStr.c_str());
    // Return the value unchanged
    return value;
}

uint64_t Elm_Kernel_Debug_todo(uint64_t message) {
    std::string msgStr = elmStringToStd(Export::toPtr(message));
    fprintf(stderr, "Debug.todo: %s\n", msgStr.c_str());
    exit(1);
    // Never reached, but needed for return type
    return 0;
}

uint64_t Elm_Kernel_Debug_toString(uint64_t value) {
    // Stub: return a placeholder string
    // Full implementation would serialize the value
    HPointer result = alloc::allocStringFromUTF8("<value>");
    return Export::encode(result);
}

} // extern "C"
