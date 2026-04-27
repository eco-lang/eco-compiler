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
#include "StringOps.hpp"
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

HPtr elm_alloc_bytebuffer(u32 byteCount) {
    auto& allocator = Elm::Allocator::instance();
    size_t total_size = sizeof(Elm::ByteBuffer) + byteCount;
    total_size = (total_size + 7) & ~7;

    Elm::ByteBuffer* bb = static_cast<Elm::ByteBuffer*>(
        allocator.allocate(total_size, Elm::Tag_ByteBuffer));
    bb->header.size = byteCount;

    return Elm::HPtr::fromBits(ptrToU64(bb));
}

u32 elm_bytebuffer_len(HPtr bbVal) {
    void* ptr = u64ToPtr(bbVal.toBits());
    if (!ptr) return 0;
    Elm::ByteBuffer* bb = static_cast<Elm::ByteBuffer*>(ptr);
    return bb->header.size;
}

u8* elm_bytebuffer_data(HPtr bbVal) {
    void* ptr = u64ToPtr(bbVal.toBits());
    if (!ptr) return nullptr;
    Elm::ByteBuffer* bb = static_cast<Elm::ByteBuffer*>(ptr);
    return bb->bytes;
}

// ============================================================================
// String Operations (UTF-8 encoding/decoding)
// ============================================================================

u32 elm_utf8_width(HPtr strVal) {
    Elm::HPointer hp = u64ToHPointer(strVal.toBits());
    if (hp.constant == Elm::Const_EmptyString + 1) {
        return 0;  // Empty string constant
    }

    void* ptr = u64ToPtr(strVal.toBits());
    if (!ptr) return 0;

    // Materialise contiguous UTF-16 via StringOps; this transparently handles
    // both flat leaves and slices so we don't need to read s->chars directly.
    auto buf = Elm::StringOps::toStdU16String(ptr);
    size_t len = buf.size();
    if (len == 0) return 0;

    u32 utf8_len = 0;
    for (size_t i = 0; i < len; ++i) {
        u32 codepoint;
        uint16_t c = buf[i];

        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < len) {
            uint16_t c2 = buf[i + 1];
            if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
                codepoint = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
                ++i;
            } else {
                codepoint = c;
            }
        } else {
            codepoint = c;
        }

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

u32 elm_utf8_copy(HPtr strVal, u8* dst) {
    Elm::HPointer hp = u64ToHPointer(strVal.toBits());
    if (hp.constant == Elm::Const_EmptyString + 1) {
        return 0;
    }

    void* ptr = u64ToPtr(strVal.toBits());
    if (!ptr) return 0;

    auto buf = Elm::StringOps::toStdU16String(ptr);
    size_t len = buf.size();
    if (len == 0) return 0;

    u8* start = dst;
    for (size_t i = 0; i < len; ++i) {
        u32 codepoint;
        uint16_t c = buf[i];

        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < len) {
            uint16_t c2 = buf[i + 1];
            if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
                codepoint = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
                ++i;
            } else {
                codepoint = c;
            }
        } else {
            codepoint = c;
        }

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

HPtr elm_utf8_decode(const u8* src, u32 len) {
    if (len == 0) {
        // Return empty string constant
        Elm::HPointer empty = Elm::alloc::emptyString();
        return Elm::HPtr::fromBits(hpointerToU64(empty));
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
            if (i + 1 >= len) return Elm::HPtr::fromBits(0);  // Invalid - incomplete sequence
            u8 c2 = src[i + 1];
            if ((c2 & 0xC0) != 0x80) return Elm::HPtr::fromBits(0);  // Invalid continuation byte
            codepoint = ((c & 0x1F) << 6) | (c2 & 0x3F);
            // Reject overlong encoding
            if (codepoint < 0x80) return Elm::HPtr::fromBits(0);
            i += 2;
        } else if ((c & 0xF0) == 0xE0) {
            // 3-byte sequence
            if (i + 2 >= len) return Elm::HPtr::fromBits(0);  // Invalid - incomplete sequence
            u8 c2 = src[i + 1];
            u8 c3 = src[i + 2];
            if ((c2 & 0xC0) != 0x80 || (c3 & 0xC0) != 0x80) return Elm::HPtr::fromBits(0);
            codepoint = ((c & 0x0F) << 12) | ((c2 & 0x3F) << 6) | (c3 & 0x3F);
            // Reject overlong encoding and surrogates
            if (codepoint < 0x800) return Elm::HPtr::fromBits(0);
            if (codepoint >= 0xD800 && codepoint <= 0xDFFF) return Elm::HPtr::fromBits(0);
            i += 3;
        } else if ((c & 0xF8) == 0xF0) {
            // 4-byte sequence
            if (i + 3 >= len) return Elm::HPtr::fromBits(0);  // Invalid - incomplete sequence
            u8 c2 = src[i + 1];
            u8 c3 = src[i + 2];
            u8 c4 = src[i + 3];
            if ((c2 & 0xC0) != 0x80 || (c3 & 0xC0) != 0x80 || (c4 & 0xC0) != 0x80)
                return Elm::HPtr::fromBits(0);
            codepoint = ((c & 0x07) << 18) | ((c2 & 0x3F) << 12) |
                        ((c3 & 0x3F) << 6) | (c4 & 0x3F);
            // Reject overlong encoding and out-of-range
            if (codepoint < 0x10000 || codepoint > 0x10FFFF) return Elm::HPtr::fromBits(0);
            i += 4;
        } else {
            return Elm::HPtr::fromBits(0);  // Invalid UTF-8 lead byte
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
    return Elm::HPtr::fromBits(hpointerToU64(result));
}

// ============================================================================
// Maybe Operations
// ============================================================================

HPtr elm_maybe_nothing() {
    Elm::HPointer nothing = Elm::alloc::nothing();
    return Elm::HPtr::fromBits(hpointerToU64(nothing));
}

HPtr elm_maybe_just(HPtr value) {
    // The value is already an eco.value (HPtr)
    // We need to wrap it in a Just
    // Elm::alloc::just expects an Elm::Unboxable and a boolean indicating if it's boxed

    // Convert HPtr back to Elm::HPointer representation for storage in the Custom type
    Elm::HPointer hp = u64ToHPointer(value.toBits());

    // For embedded constants, we store the constant directly
    // For real pointers, we store the Elm::HPointer
    Elm::Unboxable wrapped;
    wrapped.p = hp;

    Elm::HPointer justVal = Elm::alloc::just(wrapped, true);  // true = value is boxed (heap ptr)
    return Elm::HPtr::fromBits(hpointerToU64(justVal));
}

// ============================================================================
// List Operations
// ============================================================================

HPtr elm_list_reverse(HPtr listVal) {
    Elm::HPointer list = u64ToHPointer(listVal.toBits());

    // Delegate to ListOps::reverse
    Elm::HPointer reversed = Elm::ListOps::reverse(list);

    return Elm::HPtr::fromBits(hpointerToU64(reversed));
}

} // extern "C"
