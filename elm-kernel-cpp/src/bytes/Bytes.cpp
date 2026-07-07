/**
 * Elm Kernel Bytes Module - Runtime Heap Integration
 *
 * This module provides binary data encoding/decoding using the GC-managed
 * ByteBuffer type from the runtime heap.
 */

#include "Bytes.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/BytesOps.hpp"
#include "allocator/StringOps.hpp"
#include <bit>

namespace Elm::Kernel::Bytes {

using namespace Elm::BytesOps;

// Endianness type ID (distinct from Order)
constexpr u16 ENDIANNESS_TYPE_ID = 2;

// Helper to check if HPointer is Nothing
static bool isNothing(HPointer ptr) {
    return Elm::alloc::isNothing(ptr);
}

// Helper to check if system is little endian
static bool isLittleEndian() {
    return std::endian::native == std::endian::little;
}

// Helper to get endianness enum
static Endianness getEndian(bool littleEndian) {
    return littleEndian ? Endianness::LE : Endianness::BE;
}

// Helper to create a successful read result: Just(Tuple2(value, newOffset))
static HPointer readSuccessBoxed(HPointer value, i64 newOffset) {
    // 2-bit-per-slot bitmap: field 0 = kind 0 (boxed HPointer), field 1 = kind 1 (Int)
    // = bits[1:0]=00, bits[3:2]=01 => 0x4
    HPointer tuple = alloc::tuple2(alloc::boxed(value), alloc::unboxedInt(newOffset), 0x4);
    return alloc::just(alloc::boxed(tuple), true);
}

// Helper for unboxed int results
static HPointer readSuccessUnboxedInt(i64 value, i64 newOffset) {
    // 2-bit-per-slot bitmap: field 0 = kind 1 (Int), field 1 = kind 1 (Int)
    // = bits[1:0]=01, bits[3:2]=01 => 0x5
    HPointer tuple = alloc::tuple2(alloc::unboxedInt(value), alloc::unboxedInt(newOffset), 0x5);
    return alloc::just(alloc::boxed(tuple), true);
}

// Helper for unboxed float results
static HPointer readSuccessUnboxedFloat(f64 value, i64 newOffset) {
    // 2-bit-per-slot bitmap: field 0 = kind 2 (Float), field 1 = kind 1 (Int)
    // = bits[1:0]=10, bits[3:2]=01 => 0x6
    HPointer tuple = alloc::tuple2(alloc::unboxedFloat(value), alloc::unboxedInt(newOffset), 0x6);
    return alloc::just(alloc::boxed(tuple), true);
}

// ============================================================================
// Basic Operations
// ============================================================================

i64 width(void* bytes) {
    return BytesOps::length(bytes);
}

HPointer getHostEndianness() {
    // LE = { ctor: 0 }, BE = { ctor: 1 }
    u16 endianCtor = isLittleEndian() ? 0 : 1;
    return alloc::custom(endianCtor, {}, 0);
}

i64 getStringWidth(void* str) {
    // Calculate UTF-8 byte count for any String form (leaf or slice).
    auto chars = StringOps::toStdU16String(str);
    i64 width = 0;
    for (size_t i = 0; i < chars.size(); i++) {
        u16 c = chars[i];

        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < chars.size()) {
            u16 next = chars[i + 1];
            if (next >= 0xDC00 && next <= 0xDFFF) {
                width += 4;
                i++;
                continue;
            }
        }

        if (c < 0x80) {
            width += 1;
        } else if (c < 0x800) {
            width += 2;
        } else {
            width += 3;
        }
    }

    return width;
}

// ============================================================================
// Decoding
// ============================================================================

HPointer decode(void* decoder, void* bytes) {
    // Full decoder implementation is complex - stub returns Nothing
    (void)decoder;
    (void)bytes;
    return alloc::nothing();
}

HPointer decodeFailure() {
    return alloc::nothing();
}

// ============================================================================
// Read Operations
// ============================================================================

HPointer read_i8(void* bytes, i64 offset) {
    HPointer result = decodeSignedInt(bytes, offset, Width::W8, Endianness::LE);

    // Check if result is Nothing
    if (isNothing(result)) {
        return result;
    }

    // Extract the value and wrap in success tuple
    auto& allocator = Allocator::instance();
    void* justObj = allocator.resolve(result);
    Custom* custom = static_cast<Custom*>(justObj);

    // Get the unboxed int value
    i64 value = custom->values[0].i;
    return readSuccessUnboxedInt(value, offset + 1);
}

HPointer read_u8(void* bytes, i64 offset) {
    HPointer result = decodeUnsignedInt(bytes, offset, Width::W8, Endianness::LE);

    if (isNothing(result)) {
        return result;
    }

    auto& allocator = Allocator::instance();
    void* justObj = allocator.resolve(result);
    Custom* custom = static_cast<Custom*>(justObj);
    i64 value = custom->values[0].i;
    return readSuccessUnboxedInt(value, offset + 1);
}

HPointer read_i16(bool littleEndian, void* bytes, i64 offset) {
    HPointer result = decodeSignedInt(bytes, offset, Width::W16, getEndian(littleEndian));

    if (isNothing(result)) {
        return result;
    }

    auto& allocator = Allocator::instance();
    void* justObj = allocator.resolve(result);
    Custom* custom = static_cast<Custom*>(justObj);
    i64 value = custom->values[0].i;
    return readSuccessUnboxedInt(value, offset + 2);
}

HPointer read_u16(bool littleEndian, void* bytes, i64 offset) {
    HPointer result = decodeUnsignedInt(bytes, offset, Width::W16, getEndian(littleEndian));

    if (isNothing(result)) {
        return result;
    }

    auto& allocator = Allocator::instance();
    void* justObj = allocator.resolve(result);
    Custom* custom = static_cast<Custom*>(justObj);
    i64 value = custom->values[0].i;
    return readSuccessUnboxedInt(value, offset + 2);
}

HPointer read_i32(bool littleEndian, void* bytes, i64 offset) {
    HPointer result = decodeSignedInt(bytes, offset, Width::W32, getEndian(littleEndian));

    if (isNothing(result)) {
        return result;
    }

    auto& allocator = Allocator::instance();
    void* justObj = allocator.resolve(result);
    Custom* custom = static_cast<Custom*>(justObj);
    i64 value = custom->values[0].i;
    return readSuccessUnboxedInt(value, offset + 4);
}

HPointer read_u32(bool littleEndian, void* bytes, i64 offset) {
    HPointer result = decodeUnsignedInt(bytes, offset, Width::W32, getEndian(littleEndian));

    if (isNothing(result)) {
        return result;
    }

    auto& allocator = Allocator::instance();
    void* justObj = allocator.resolve(result);
    Custom* custom = static_cast<Custom*>(justObj);
    i64 value = custom->values[0].i;
    return readSuccessUnboxedInt(value, offset + 4);
}

HPointer read_f32(bool littleEndian, void* bytes, i64 offset) {
    HPointer result = decodeFloat32(bytes, offset, getEndian(littleEndian));

    if (isNothing(result)) {
        return result;
    }

    auto& allocator = Allocator::instance();
    void* justObj = allocator.resolve(result);
    Custom* custom = static_cast<Custom*>(justObj);
    f64 value = custom->values[0].f;
    return readSuccessUnboxedFloat(value, offset + 4);
}

HPointer read_f64(bool littleEndian, void* bytes, i64 offset) {
    HPointer result = decodeFloat64(bytes, offset, getEndian(littleEndian));

    if (isNothing(result)) {
        return result;
    }

    auto& allocator = Allocator::instance();
    void* justObj = allocator.resolve(result);
    Custom* custom = static_cast<Custom*>(justObj);
    f64 value = custom->values[0].f;
    return readSuccessUnboxedFloat(value, offset + 8);
}

HPointer read_bytes(i64 length, void* bytes, i64 offset) {
    size_t buf_len = alloc::byteBufferLength(bytes);
    if (offset < 0 || static_cast<size_t>(offset + length) > buf_len) {
        return decodeFailure();
    }

    HPointer resultBytes = BytesOps::slice(bytes, offset, offset + length);
    return readSuccessBoxed(resultBytes, offset + length);
}

HPointer read_string(i64 length, void* bytes, i64 offset) {
    // The legacy form allocated a slice ByteBuffer, then ran decodeUtf8
    // which allocates a u16string + a fresh ElmString — three allocations,
    // two memcpys, all just to land on a string. Decode directly into a
    // fresh ElmString sized to the exact UTF-16 code-unit count instead.
    auto& allocator = Allocator::instance();
    auto buf_view = alloc::byteBufferView(bytes);

    if (offset < 0 || static_cast<size_t>(offset + length) > buf_view.length) {
        return decodeFailure();
    }

    if (length == 0) {
        return readSuccessBoxed(alloc::emptyString(), offset);
    }

    HPointer srcHP = allocator.wrap(bytes);
    const u8* src = buf_view.data + offset;

    // Pass 1: count UTF-16 code units. `src` lives in the source buffer;
    // no allocation here, so the pointer is stable.
    size_t units = 0;
    for (i64 i = 0; i < length; ) {
        u8 c = src[i];
        if (c < 0x80) { ++units; i += 1; }
        else if (c < 0xE0) { ++units; i += 2; }
        else if (c < 0xF0) { ++units; i += 3; }
        else { units += 2; i += 4; }
    }

    // Pass 2: allocate ElmString of exact size with srcHP rooted so we
    // can re-derive a stable byte pointer for the decode walk.
    alloc::BlankString bs;
    {
        StackRootRangeGuard guard(&srcHP, 1, 0x1);
        bs = alloc::allocStringBlank(units);
    }

    auto src_view2 = alloc::byteBufferView(allocator.resolve(srcHP));
    const u8* src2 = src_view2.data + offset;
    size_t dst = 0;
    for (i64 i = 0; i < length; ) {
        u8 c = src2[i];
        u32 cp;
        if (c < 0x80) { cp = c; i += 1; }
        else if (c < 0xE0) {
            cp = ((c & 0x1F) << 6) | (src2[i + 1] & 0x3F);
            i += 2;
        } else if (c < 0xF0) {
            cp = ((c & 0x0F) << 12) | ((src2[i + 1] & 0x3F) << 6) | (src2[i + 2] & 0x3F);
            i += 3;
        } else {
            cp = ((c & 0x07) << 18) | ((src2[i + 1] & 0x3F) << 12) |
                 ((src2[i + 2] & 0x3F) << 6) | (src2[i + 3] & 0x3F);
            i += 4;
        }
        if (cp <= 0xFFFF) {
            bs.chars[dst++] = static_cast<u16>(cp);
        } else {
            cp -= 0x10000;
            bs.chars[dst++] = static_cast<u16>(0xD800 | (cp >> 10));
            bs.chars[dst++] = static_cast<u16>(0xDC00 | (cp & 0x3FF));
        }
    }

    return readSuccessBoxed(bs.hp, offset + length);
}

// ============================================================================
// Write Operations
// ============================================================================

HPointer write_i8(i64 value) {
    return encodeSignedInt(value, Width::W8, Endianness::LE);
}

HPointer write_u8(i64 value) {
    return encodeUnsignedInt(static_cast<u64>(value), Width::W8, Endianness::LE);
}

HPointer write_i16(bool littleEndian, i64 value) {
    return encodeSignedInt(value, Width::W16, getEndian(littleEndian));
}

HPointer write_u16(bool littleEndian, i64 value) {
    return encodeUnsignedInt(static_cast<u64>(value), Width::W16, getEndian(littleEndian));
}

HPointer write_i32(bool littleEndian, i64 value) {
    return encodeSignedInt(value, Width::W32, getEndian(littleEndian));
}

HPointer write_u32(bool littleEndian, i64 value) {
    return encodeUnsignedInt(static_cast<u64>(value), Width::W32, getEndian(littleEndian));
}

HPointer write_f32(bool littleEndian, f64 value) {
    return encodeFloat32(value, getEndian(littleEndian));
}

HPointer write_f64(bool littleEndian, f64 value) {
    return encodeFloat64(value, getEndian(littleEndian));
}

HPointer write_bytes(void* bytes) {
    // ByteBuffers are immutable; share by reference rather than copying.
    // The legacy form did fromData(b->bytes, b->header.size) which
    // round-tripped the entire payload through a fresh allocation.
    return Allocator::instance().wrap(bytes);
}

HPointer write_string(void* str) {
    return BytesOps::encodeUtf8(str);
}

// ============================================================================
// Encoding
// ============================================================================

HPointer encode(HPointer encoderList) {
    return BytesOps::concat(encoderList);
}

} // namespace Elm::Kernel::Bytes
