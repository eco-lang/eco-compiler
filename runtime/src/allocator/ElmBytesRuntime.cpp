/**
 * Byte Fusion Runtime ABI Implementation.
 *
 * This file implements the C ABI functions for the bf MLIR dialect.
 * All eco.value ↔ pointer conversions are encapsulated here.
 *
 * Layout access rules:
 * - These functions are the ONLY code allowed to access header.size and
 *   struct internals directly for Elm::ByteBuffer/Elm::ElmString.
 * - Generated MLIR/LLVM code calls these helpers instead of GEPs.
 *
 * Implementation approach:
 * - Delegates to existing runtime infrastructure where possible
 * - UTF-8 encoding/decoding logic matches BytesOps.cpp
 */

#include "ElmBytesRuntime.h"
#include "Heap.hpp"
#include "HeapHelpers.hpp"
#include "Allocator.hpp"
#include "ListOps.hpp"
#include <cstring>
#include <string>
#include <vector>

// Note: Don't use `using namespace Elm;` to avoid conflict with global u64 typedef

// ============================================================================
// Internal Helper: eco.value ↔ pointer/Elm::HPointer conversion
// ============================================================================

namespace {

// Convert eco.value (uint64_t) to Elm::HPointer (bitcast)
inline Elm::HPointer u64ToHPointer(uint64_t val) {
    Elm::HPointer hp;
    std::memcpy(&hp, &val, sizeof(hp));
    return hp;
}

// Convert Elm::HPointer to eco.value (uint64_t) (bitcast)
inline uint64_t hpointerToU64(Elm::HPointer hp) {
    uint64_t result;
    std::memcpy(&result, &hp, sizeof(result));
    return result;
}

// Convert eco.value (uint64_t) to raw pointer
// For heap objects (constant=0), resolves via Elm::Allocator
// For embedded constants (constant!=0), returns nullptr
inline void* u64ToPtr(uint64_t val) {
    Elm::HPointer hp = u64ToHPointer(val);
    if (hp.constant != 0) {
        return nullptr;  // Embedded constant has no heap object
    }
    return Elm::Allocator::instance().resolve(hp);
}

// Convert raw pointer to eco.value (uint64_t)
inline uint64_t ptrToU64(void* obj) {
    Elm::HPointer hp = Elm::Allocator::instance().wrap(obj);
    return hpointerToU64(hp);
}

} // anonymous namespace

// ============================================================================
// Elm::ByteBuffer Operations
// ============================================================================

extern "C" {

u64 elm_alloc_bytebuffer(u32 byteCount) {
    // Use existing allocator infrastructure
    auto& allocator = Elm::Allocator::instance();
    size_t total_size = sizeof(Elm::ByteBuffer) + byteCount;
    total_size = (total_size + 7) & ~7;  // 8-byte alignment

    Elm::ByteBuffer* bb = static_cast<Elm::ByteBuffer*>(
        allocator.allocate(total_size, Elm::Tag_ByteBuffer));
    bb->header.size = byteCount;

    return ptrToU64(bb);
}

u32 elm_bytebuffer_len(u64 bbVal) {
    void* ptr = u64ToPtr(bbVal);
    if (!ptr) return 0;  // Embedded constant (shouldn't happen for Elm::ByteBuffer)
    Elm::ByteBuffer* bb = static_cast<Elm::ByteBuffer*>(ptr);
    return bb->header.size;
}

u8* elm_bytebuffer_data(u64 bbVal) {
    void* ptr = u64ToPtr(bbVal);
    if (!ptr) return nullptr;  // Embedded constant (shouldn't happen)
    Elm::ByteBuffer* bb = static_cast<Elm::ByteBuffer*>(ptr);
    return bb->bytes;
}

// ============================================================================
// String Operations (UTF-8 encoding/decoding)
// ============================================================================

u32 elm_utf8_width(u64 strVal) {
    // Check for empty string constant
    Elm::HPointer hp = u64ToHPointer(strVal);
    if (hp.constant == Elm::Const_EmptyString + 1) {
        return 0;  // Empty string has 0 UTF-8 bytes
    }

    void* ptr = u64ToPtr(strVal);
    if (!ptr) return 0;  // Other embedded constant (shouldn't happen)

    Elm::ElmString* s = static_cast<Elm::ElmString*>(ptr);
    size_t len = s->header.size;

    if (len == 0) return 0;

    // Calculate UTF-8 byte width from UTF-16 code units
    u32 utf8_len = 0;

    for (size_t i = 0; i < len; ++i) {
        u32 codepoint;
        uint16_t c = s->chars[i];

        // Handle surrogate pairs
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < len) {
            uint16_t c2 = s->chars[i + 1];
            if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
                codepoint = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
                ++i;  // Skip second surrogate
            } else {
                codepoint = c;
            }
        } else {
            codepoint = c;
        }

        // Count UTF-8 bytes needed for this codepoint
        if (codepoint < 0x80) {
            utf8_len += 1;
        } else if (codepoint < 0x800) {
            utf8_len += 2;
        } else if (codepoint < 0x10000) {
            utf8_len += 3;
        } else {
            utf8_len += 4;
        }
    }

    return utf8_len;
}

u32 elm_utf8_copy(u64 strVal, u8* dst) {
    // Check for empty string constant
    Elm::HPointer hp = u64ToHPointer(strVal);
    if (hp.constant == Elm::Const_EmptyString + 1) {
        return 0;  // Empty string - nothing to copy
    }

    void* ptr = u64ToPtr(strVal);
    if (!ptr) return 0;  // Other embedded constant (shouldn't happen)

    Elm::ElmString* s = static_cast<Elm::ElmString*>(ptr);
    size_t len = s->header.size;

    if (len == 0) return 0;

    u8* start = dst;

    for (size_t i = 0; i < len; ++i) {
        u32 codepoint;
        uint16_t c = s->chars[i];

        // Handle surrogate pairs
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < len) {
            uint16_t c2 = s->chars[i + 1];
            if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
                codepoint = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
                ++i;  // Skip second surrogate
            } else {
                codepoint = c;
            }
        } else {
            codepoint = c;
        }

        // Encode as UTF-8
        if (codepoint < 0x80) {
            *dst++ = static_cast<u8>(codepoint);
        } else if (codepoint < 0x800) {
            *dst++ = static_cast<u8>(0xC0 | (codepoint >> 6));
            *dst++ = static_cast<u8>(0x80 | (codepoint & 0x3F));
        } else if (codepoint < 0x10000) {
            *dst++ = static_cast<u8>(0xE0 | (codepoint >> 12));
            *dst++ = static_cast<u8>(0x80 | ((codepoint >> 6) & 0x3F));
            *dst++ = static_cast<u8>(0x80 | (codepoint & 0x3F));
        } else {
            *dst++ = static_cast<u8>(0xF0 | (codepoint >> 18));
            *dst++ = static_cast<u8>(0x80 | ((codepoint >> 12) & 0x3F));
            *dst++ = static_cast<u8>(0x80 | ((codepoint >> 6) & 0x3F));
            *dst++ = static_cast<u8>(0x80 | (codepoint & 0x3F));
        }
    }

    return static_cast<u32>(dst - start);
}

u64 elm_utf8_decode(const u8* src, u32 len) {
    if (len == 0) {
        // Return empty string constant
        Elm::HPointer empty = Elm::alloc::emptyString();
        return hpointerToU64(empty);
    }

    // Decode UTF-8 to UTF-16
    std::u16string utf16;
    utf16.reserve(len);  // Worst case

    size_t i = 0;
    while (i < len) {
        u8 c = src[i];
        u32 codepoint;

        if ((c & 0x80) == 0) {
            // 1-byte (ASCII)
            codepoint = c;
            i += 1;
        } else if ((c & 0xE0) == 0xC0) {
            // 2-byte sequence
            if (i + 1 >= len) return 0;  // Invalid - incomplete sequence
            u8 c2 = src[i + 1];
            if ((c2 & 0xC0) != 0x80) return 0;  // Invalid continuation byte
            codepoint = ((c & 0x1F) << 6) | (c2 & 0x3F);
            // Reject overlong encoding
            if (codepoint < 0x80) return 0;
            i += 2;
        } else if ((c & 0xF0) == 0xE0) {
            // 3-byte sequence
            if (i + 2 >= len) return 0;  // Invalid - incomplete sequence
            u8 c2 = src[i + 1];
            u8 c3 = src[i + 2];
            if ((c2 & 0xC0) != 0x80 || (c3 & 0xC0) != 0x80) return 0;
            codepoint = ((c & 0x0F) << 12) | ((c2 & 0x3F) << 6) | (c3 & 0x3F);
            // Reject overlong encoding and surrogates
            if (codepoint < 0x800) return 0;
            if (codepoint >= 0xD800 && codepoint <= 0xDFFF) return 0;
            i += 3;
        } else if ((c & 0xF8) == 0xF0) {
            // 4-byte sequence
            if (i + 3 >= len) return 0;  // Invalid - incomplete sequence
            u8 c2 = src[i + 1];
            u8 c3 = src[i + 2];
            u8 c4 = src[i + 3];
            if ((c2 & 0xC0) != 0x80 || (c3 & 0xC0) != 0x80 || (c4 & 0xC0) != 0x80)
                return 0;
            codepoint = ((c & 0x07) << 18) | ((c2 & 0x3F) << 12) |
                        ((c3 & 0x3F) << 6) | (c4 & 0x3F);
            // Reject overlong encoding and out-of-range
            if (codepoint < 0x10000 || codepoint > 0x10FFFF) return 0;
            i += 4;
        } else {
            return 0;  // Invalid UTF-8 lead byte
        }

        // Convert codepoint to UTF-16
        if (codepoint <= 0xFFFF) {
            utf16.push_back(static_cast<char16_t>(codepoint));
        } else {
            // Surrogate pair for codepoints > 0xFFFF
            codepoint -= 0x10000;
            utf16.push_back(static_cast<char16_t>(0xD800 | (codepoint >> 10)));
            utf16.push_back(static_cast<char16_t>(0xDC00 | (codepoint & 0x3FF)));
        }
    }

    // Allocate Elm::ElmString with UTF-16 content
    Elm::HPointer result = Elm::alloc::allocString(utf16);
    return hpointerToU64(result);
}

// ============================================================================
// Maybe Operations
// ============================================================================

u64 elm_maybe_nothing() {
    Elm::HPointer nothing = Elm::alloc::nothing();
    return hpointerToU64(nothing);
}

u64 elm_maybe_just(u64 value) {
    // The value is already an eco.value (u64)
    // We need to wrap it in a Just
    // Elm::alloc::just expects an Elm::Unboxable and a boolean indicating if it's boxed

    // Convert u64 back to Elm::HPointer representation for storage in the Custom type
    Elm::HPointer hp = u64ToHPointer(value);

    // For embedded constants, we store the constant directly
    // For real pointers, we store the Elm::HPointer
    Elm::Unboxable wrapped;
    wrapped.p = hp;

    Elm::HPointer justVal = Elm::alloc::just(wrapped, true);  // true = value is boxed (heap ptr)
    return hpointerToU64(justVal);
}

// ============================================================================
// List Operations
// ============================================================================

u64 elm_list_reverse(u64 listVal) {
    Elm::HPointer list = u64ToHPointer(listVal);

    // Delegate to ListOps::reverse
    Elm::HPointer reversed = Elm::ListOps::reverse(list);

    return hpointerToU64(reversed);
}

} // extern "C"
