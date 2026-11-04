#include "Bytes.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/BytesOps.hpp"
#include "allocator/StringOps.hpp"
#include <bit>

namespace Elm::Kernel::Bytes {

using namespace Elm::BytesOps;

/// A type id for `Endianness`. Nothing reads it.
constexpr u16 ENDIANNESS_TYPE_ID = 2;

/// Returns whether `ptr` is Nothing.
static bool isNothing(HPointer ptr) {
    return Elm::alloc::isNothing(ptr);
}

/// Returns whether the host is little-endian.
static bool isLittleEndian() {
    return std::endian::native == std::endian::little;
}

/// Returns the `BytesOps` endianness that `littleEndian` stands for.
static Endianness getEndian(bool littleEndian) {
    return littleEndian ? Endianness::LE : Endianness::BE;
}

/// Returns `Just(Tuple2(value, newOffset))` with `value` boxed and `newOffset` an unboxed Int.
static HPointer readSuccessBoxed(HPointer value, i64 newOffset) {
    // 2-bit-per-slot bitmap: field 0 = kind 0 (boxed HPointer), field 1 = kind 1 (Int)
    // = bits[1:0]=00, bits[3:2]=01 => 0x4
    HPointer tuple = alloc::tuple2(alloc::boxed(value), alloc::unboxedInt(newOffset), 0x4);
    return alloc::just(alloc::boxed(tuple), true);
}

/// Returns `Just(Tuple2(value, newOffset))` with both fields unboxed Ints.
static HPointer readSuccessUnboxedInt(i64 value, i64 newOffset) {
    // 2-bit-per-slot bitmap: field 0 = kind 1 (Int), field 1 = kind 1 (Int)
    // = bits[1:0]=01, bits[3:2]=01 => 0x5
    HPointer tuple = alloc::tuple2(alloc::unboxedInt(value), alloc::unboxedInt(newOffset), 0x5);
    return alloc::just(alloc::boxed(tuple), true);
}

/// Returns `Just(Tuple2(value, newOffset))` with `value` an unboxed Float and `newOffset` an unboxed
/// Int.
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
    u16 endianCtor = isLittleEndian() ? 0 : 1;
    return alloc::custom(endianCtor, {}, 0);
}

i64 getStringWidth(void* str) {
    // UTF-8 (ASCII) forms: byte width == logical length. O(1).
    if (StringOps::isUtf8(str)) return StringOps::length(str);
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

    if (isNothing(result)) {
        return result;
    }

    auto& allocator = Allocator::instance();
    void* justObj = allocator.resolve(result);
    Custom* custom = static_cast<Custom*>(justObj);
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
    // ByteBuffers are immutable, so the value is shared rather than copied. A null object stands
    // for the empty Bytes, which is an embedded constant rather than a heap object.
    if (!bytes) return alloc::emptyBytes();
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
