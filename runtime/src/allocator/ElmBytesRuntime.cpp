#include "ElmBytesRuntime.h"
#include "Heap.hpp"
#include "HeapHelpers.hpp"
#include "Allocator.hpp"
#include "ListOps.hpp"
#include "StringOps.hpp"
#include <cstring>
#include <string>
#include <vector>

// Names from `Elm` are qualified in full, because the header also declares `u8` and `u32` at global scope.

// ============================================================================
// Internal Helper: eco.value ↔ pointer/Elm::HPointer conversion
// ============================================================================

namespace {

/// Returns the HPointer whose word is `val`.
inline Elm::HPointer u64ToHPointer(uint64_t val) {
    Elm::HPointer hp;
    std::memcpy(&hp, &val, sizeof(hp));
    return hp;
}

/// Returns the word of `hp`.
inline uint64_t hpointerToU64(Elm::HPointer hp) {
    uint64_t result;
    std::memcpy(&result, &hp, sizeof(result));
    return result;
}

/// Returns the heap object the word `val` refers to, or null when `val` is an embedded constant
/// (`ptr_ind` set). The null word 0 is not a constant and is passed to `resolve`.
inline void* u64ToPtr(uint64_t val) {
    Elm::HPointer hp = u64ToHPointer(val);
    if (hp.ptr_ind != 0) {
        return nullptr;
    }
    return Elm::Allocator::instance().resolve(hp);
}

} // anonymous namespace

// ============================================================================
// Elm::ByteBuffer Operations
// ============================================================================

extern "C" {

HPtr elm_alloc_bytebuffer(u32 byteCount) {
    Elm::alloc::BlankByteBuffer bb = Elm::alloc::allocByteBufferBlank(byteCount);
    return Elm::HPtr::fromBits(hpointerToU64(bb.hp));
}

u32 elm_bytebuffer_len(HPtr bbVal) {
    void* ptr = u64ToPtr(bbVal.toBits());
    if (!ptr) return 0;
    // Not `resolveByteBufferBody`, which asserts on a slice.
    return static_cast<u32>(Elm::alloc::byteBufferLength(ptr));
}

u8* elm_bytebuffer_data(HPtr bbVal) {
    void* ptr = u64ToPtr(bbVal.toBits());
    if (!ptr) return nullptr;
    return const_cast<u8*>(Elm::alloc::byteBufferData(ptr));
}

void elm_bytebuffer_with_data(HPtr bbVal, elm_bytebuffer_callback fn, void* ctx) {
    if (!fn) return;
    void* ptr = u64ToPtr(bbVal.toBits());
    if (!ptr) {
        fn(nullptr, 0, ctx);
        return;
    }
    auto v = Elm::alloc::byteBufferView(ptr);
    fn(v.data, static_cast<u32>(v.length), ctx);
}

void elm_bytebuffer_builder_begin(HPtr bbVal) {
    void* ptr = u64ToPtr(bbVal.toBits());
    if (!ptr) return;
    Elm::alloc::mark_as_builder(static_cast<Elm::Header*>(ptr));
}

void elm_bytebuffer_builder_end(HPtr bbVal) {
    void* ptr = u64ToPtr(bbVal.toBits());
    if (!ptr) return;
    Elm::alloc::clear_builder(static_cast<Elm::Header*>(ptr));
}

// ============================================================================
// String Operations (UTF-8 encoding/decoding)
// ============================================================================

u32 elm_utf8_width(HPtr strVal) {
    Elm::HPointer hp = u64ToHPointer(strVal.toBits());
    if (Elm::alloc::isEmptyString(hp)) {
        return 0;
    }

    void* ptr = u64ToPtr(strVal.toBits());
    if (!ptr) return 0;

    // A UTF-8 form holds only ASCII, so its length in units is its width in bytes.
    if (Elm::StringOps::isUtf8(ptr)) {
        return static_cast<u32>(Elm::StringOps::length(ptr));
    }

    // Copied out to C++ memory so that every UTF-16 form (leaf, slice, rope) is read the same way.
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
    if (Elm::alloc::isEmptyString(hp)) {
        return 0;
    }

    void* ptr = u64ToPtr(strVal.toBits());
    if (!ptr) return 0;

    // A UTF-8 form holds only ASCII, which is already its UTF-8 encoding.
    if (Elm::StringOps::isUtf8(ptr)) {
        auto pr = Elm::StringOps::utf8Bytes(ptr);
        std::memcpy(dst, pr.first, pr.second);
        return pr.second;
    }

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

HPtr elm_utf8_decode(HPtr buffer, u32 offset, u32 len) {
    if (len == 0) {
        Elm::HPointer empty = Elm::alloc::emptyString();
        return Elm::HPtr::fromBits(hpointerToU64(empty));
    }

    // Pass 1 validates and counts UTF-16 units. `src` may point into a nursery buffer, so it is valid only
    // until the allocation below.
    const u8* src = elm_bytebuffer_data(buffer) + offset;
    size_t units = 0;
    for (u32 i = 0; i < len; ) {
        u8 c = src[i];
        if ((c & 0x80) == 0) {
            ++units; i += 1;
        } else if ((c & 0xE0) == 0xC0) {
            if (i + 1 >= len) return Elm::HPtr::fromBits(0);
            u8 c2 = src[i + 1];
            if ((c2 & 0xC0) != 0x80) return Elm::HPtr::fromBits(0);
            u32 cp = ((c & 0x1F) << 6) | (c2 & 0x3F);
            if (cp < 0x80) return Elm::HPtr::fromBits(0);
            ++units; i += 2;
        } else if ((c & 0xF0) == 0xE0) {
            if (i + 2 >= len) return Elm::HPtr::fromBits(0);
            u8 c2 = src[i + 1], c3 = src[i + 2];
            if ((c2 & 0xC0) != 0x80 || (c3 & 0xC0) != 0x80)
                return Elm::HPtr::fromBits(0);
            u32 cp = ((c & 0x0F) << 12) | ((c2 & 0x3F) << 6) | (c3 & 0x3F);
            if (cp < 0x800) return Elm::HPtr::fromBits(0);
            if (cp >= 0xD800 && cp <= 0xDFFF) return Elm::HPtr::fromBits(0);
            ++units; i += 3;
        } else if ((c & 0xF8) == 0xF0) {
            if (i + 3 >= len) return Elm::HPtr::fromBits(0);
            u8 c2 = src[i + 1], c3 = src[i + 2], c4 = src[i + 3];
            if ((c2 & 0xC0) != 0x80 || (c3 & 0xC0) != 0x80 || (c4 & 0xC0) != 0x80)
                return Elm::HPtr::fromBits(0);
            u32 cp = ((c & 0x07) << 18) | ((c2 & 0x3F) << 12) |
                     ((c3 & 0x3F) << 6) | (c4 & 0x3F);
            if (cp < 0x10000 || cp > 0x10FFFF) return Elm::HPtr::fromBits(0);
            units += 2; i += 4;
        } else {
            return Elm::HPtr::fromBits(0);
        }
    }

    // Pass 2 decodes straight into the new String. The allocation may move a nursery buffer, so the buffer is
    // rooted across it and `src` is found again afterwards. The bytes were validated by pass 1, so this pass
    // checks nothing.
    Elm::HPointer bufHp = u64ToHPointer(buffer.toBits());
    Elm::alloc::BlankString bs;
    {
        Elm::StackRootGuard guard(&bufHp);
        bs = Elm::alloc::allocStringBlank(units);
    }
    src = elm_bytebuffer_data(Elm::HPtr::fromBits(hpointerToU64(bufHp))) + offset;
    size_t dst = 0;
    for (u32 i = 0; i < len; ) {
        u8 c = src[i];
        u32 cp;
        if ((c & 0x80) == 0) {
            cp = c; i += 1;
        } else if ((c & 0xE0) == 0xC0) {
            cp = ((c & 0x1F) << 6) | (src[i + 1] & 0x3F);
            i += 2;
        } else if ((c & 0xF0) == 0xE0) {
            cp = ((c & 0x0F) << 12) | ((src[i + 1] & 0x3F) << 6) | (src[i + 2] & 0x3F);
            i += 3;
        } else {
            cp = ((c & 0x07) << 18) | ((src[i + 1] & 0x3F) << 12) |
                 ((src[i + 2] & 0x3F) << 6) | (src[i + 3] & 0x3F);
            i += 4;
        }
        if (cp <= 0xFFFF) {
            bs.chars[dst++] = static_cast<char16_t>(cp);
        } else {
            cp -= 0x10000;
            bs.chars[dst++] = static_cast<char16_t>(0xD800 | (cp >> 10));
            bs.chars[dst++] = static_cast<char16_t>(0xDC00 | (cp & 0x3FF));
        }
    }
    return Elm::HPtr::fromBits(hpointerToU64(bs.hp));
}

// ============================================================================
// Maybe Operations
// ============================================================================

HPtr elm_maybe_nothing() {
    Elm::HPointer nothing = Elm::alloc::nothing();
    return Elm::HPtr::fromBits(hpointerToU64(nothing));
}

HPtr elm_maybe_just(HPtr value) {
    Elm::HPointer hp = u64ToHPointer(value.toBits());

    Elm::Unboxable wrapped;
    wrapped.p = hp;

    Elm::HPointer justVal = Elm::alloc::just(wrapped, true);  // true: boxed
    return Elm::HPtr::fromBits(hpointerToU64(justVal));
}

// ============================================================================
// List Operations
// ============================================================================

HPtr elm_list_reverse(HPtr listVal) {
    Elm::HPointer list = u64ToHPointer(listVal.toBits());

    Elm::HPointer reversed = Elm::ListOps::reverse(list);

    return Elm::HPtr::fromBits(hpointerToU64(reversed));
}

} // extern "C"
