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
    return ptr.constant == Const_Nothing + 1;
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
    HPointer tuple = alloc::tuple2(alloc::boxed(value), alloc::unboxedInt(newOffset), 0x2);
    return alloc::just(alloc::boxed(tuple), true);
}

// Helper for unboxed int results
static HPointer readSuccessUnboxedInt(i64 value, i64 newOffset) {
    HPointer tuple = alloc::tuple2(alloc::unboxedInt(value), alloc::unboxedInt(newOffset), 0x3);
    return alloc::just(alloc::boxed(tuple), true);
}

// Helper for unboxed float results
static HPointer readSuccessUnboxedFloat(f64 value, i64 newOffset) {
    HPointer tuple = alloc::tuple2(alloc::unboxedFloat(value), alloc::unboxedInt(newOffset), 0x2);
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
    // Calculate UTF-8 byte count for an ElmString
    ElmString* s = static_cast<ElmString*>(str);
    i64 width = 0;

    for (u32 i = 0; i < s->header.size; i++) {
        u16 c = s->chars[i];

        // Handle surrogate pairs
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s->header.size) {
            u16 next = s->chars[i + 1];
            if (next >= 0xDC00 && next <= 0xDFFF) {
                // Surrogate pair: 4 UTF-8 bytes
                width += 4;
                i++;
                continue;
            }
        }

        // Regular characters
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
    ByteBuffer* b = static_cast<ByteBuffer*>(bytes);

    if (offset < 0 || static_cast<size_t>(offset + length) > b->header.size) {
        return decodeFailure();
    }

    HPointer resultBytes = BytesOps::slice(bytes, offset, offset + length);
    return readSuccessBoxed(resultBytes, offset + length);
}

HPointer read_string(i64 length, void* bytes, i64 offset) {
    ByteBuffer* b = static_cast<ByteBuffer*>(bytes);

    if (offset < 0 || static_cast<size_t>(offset + length) > b->header.size) {
        return decodeFailure();
    }

    // Create a slice and decode as UTF-8
    HPointer slice = BytesOps::slice(bytes, offset, offset + length);
    auto& allocator = Allocator::instance();
    void* sliceObj = allocator.resolve(slice);

    HPointer stringResult = BytesOps::decodeUtf8(sliceObj);

    if (isNothing(stringResult)) {
        return decodeFailure();
    }

    // Extract string from Just
    void* justObj = allocator.resolve(stringResult);
    Custom* custom = static_cast<Custom*>(justObj);
    HPointer str = custom->values[0].p;

    return readSuccessBoxed(str, offset + length);
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
    // Just return a copy (ByteBuffer is immutable)
    ByteBuffer* b = static_cast<ByteBuffer*>(bytes);
    return BytesOps::fromData(b->bytes, b->header.size);
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
