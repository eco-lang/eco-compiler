/**
 * Binary Data Operations for Elm Runtime.
 *
 * This file provides byte buffer manipulation utilities that work with the
 * GC-managed heap. Functions operate on ByteBuffer objects for binary data
 * processing (files, network, encoding, etc.).
 *
 * ByteBuffer representation:
 *   - header.size: Number of bytes
 *   - bytes[]: Raw byte data (u8 array)
 *   - Immutable: Operations return new ByteBuffers
 *
 * Key operations:
 *   - Creation: empty, fromList, fromString
 *   - Access: length, getAt, slice
 *   - Encoding: encode (int/float), decode (int/float)
 *   - Conversion: toString (UTF-8), toList
 *   - Width: Support for 8/16/32 bit integers and 32/64 bit floats
 *   - Endianness: Big-endian (BE) and little-endian (LE) support
 */

#ifndef ECO_BYTES_OPS_H
#define ECO_BYTES_OPS_H

#include "Allocator.hpp"
#include "HeapHelpers.hpp"
#include <cstring>
#include <vector>

namespace Elm {
namespace BytesOps {

// ============================================================================
// Endianness
// ============================================================================

enum class Endianness {
    LE,  // Little-endian (x86, ARM)
    BE   // Big-endian (network byte order)
};

// ============================================================================
// Width for integer encoding
// ============================================================================

enum class Width {
    W8   = 1,   // 1 byte
    W16  = 2,   // 2 bytes
    W32  = 4,   // 4 bytes
};

// ============================================================================
// Creation
// ============================================================================

/**
 * Creates an empty ByteBuffer.
 */
inline HPointer empty() {
    return alloc::allocByteBuffer(nullptr, 0);
}

/**
 * Creates a ByteBuffer from a list of integers (0-255).
 * Values outside 0-255 are truncated to their low 8 bits.
 */
HPointer fromList(HPointer list);

/**
 * Creates a ByteBuffer from raw data.
 */
inline HPointer fromData(const u8* data, size_t length) {
    return alloc::allocByteBuffer(data, length);
}

/**
 * Creates a ByteBuffer from a std::vector of bytes.
 */
inline HPointer fromVector(const std::vector<u8>& vec) {
    return alloc::allocByteBuffer(vec.data(), vec.size());
}

/**
 * Creates a ByteBuffer from a UTF-8 encoded string.
 */
HPointer fromString(void* str);

// ============================================================================
// Access
// ============================================================================

/**
 * Returns the number of bytes in a ByteBuffer (any form).
 */
inline i64 length(void* buf) {
    return static_cast<i64>(alloc::byteBufferLength(buf));
}

/**
 * Returns the byte at a given index (0-based).
 * Returns -1 if index is out of bounds. Handles all ByteBuffer forms via
 * byteBufferView (flat, large-header, or slice).
 */
inline i64 getAt(void* buf, i64 index) {
    auto v = alloc::byteBufferView(buf);
    if (index < 0 || static_cast<size_t>(index) >= v.length) {
        return -1;
    }
    return static_cast<i64>(v.data[index]);
}

/**
 * Extracts a slice from start (inclusive) to end (exclusive).
 *
 * Produces a Tag_ByteBufferSlice over the source for slices of length
 * >= MAKE_BYTEBUFFER_SLICE_MIN_LEN — no payload memcpy, just a 16-byte
 * view header with HPointer + offset. The view layer (byteBufferView)
 * follows slice-of-slice and Tag_LargeByteHeader indirections.
 *
 * For tiny slices, makeByteBufferSlice flattens to a copy so we don't
 * pay the indirection cost on small ranges.
 */
inline HPointer slice(void* buf, i64 start, i64 end) {
    auto& allocator = Allocator::instance();
    size_t buf_len = alloc::byteBufferLength(buf);
    i64 len = static_cast<i64>(buf_len);

    start = std::max(i64(0), std::min(start, len));
    end = std::max(i64(0), std::min(end, len));
    if (start >= end) return empty();

    u32 slice_len = static_cast<u32>(end - start);
    HPointer baseHP = allocator.wrap(buf);
    return alloc::makeByteBufferSlice(baseHP, static_cast<u32>(start), slice_len);
}

// ============================================================================
// Encoding - Integers
// ============================================================================

/**
 * Encodes an unsigned integer into bytes.
 *
 * @param value  The integer value to encode.
 * @param width  Number of bytes (1, 2, or 4).
 * @param endian Byte order (LE or BE).
 * @return ByteBuffer containing the encoded integer.
 */
inline HPointer encodeUnsignedInt(u64 value, Width width, Endianness endian) {
    size_t w = static_cast<size_t>(width);
    u8 bytes[4];

    // Pack low byte first, then byteswap below for BE. Clang lowers the
    // <= 4-byte memcpy + bswap pair to a movbe / bswap pair on x86, which
    // is materially better than the manual shift loop the original code
    // emitted (compiler couldn't reliably recover the bswap idiom).
    switch (width) {
        case Width::W8: {
            bytes[0] = static_cast<u8>(value & 0xFF);
            break;
        }
        case Width::W16: {
            u16 v16 = static_cast<u16>(value);
            if (endian == Endianness::BE) v16 = __builtin_bswap16(v16);
            std::memcpy(bytes, &v16, 2);
            break;
        }
        case Width::W32: {
            u32 v32 = static_cast<u32>(value);
            if (endian == Endianness::BE) v32 = __builtin_bswap32(v32);
            std::memcpy(bytes, &v32, 4);
            break;
        }
    }

    return alloc::allocByteBuffer(bytes, w);
}

/**
 * Encodes a signed integer into bytes (two's complement).
 */
inline HPointer encodeSignedInt(i64 value, Width width, Endianness endian) {
    return encodeUnsignedInt(static_cast<u64>(value), width, endian);
}

/**
 * Decodes an unsigned integer from bytes.
 *
 * @param buf    ByteBuffer containing the encoded integer.
 * @param offset Byte offset to start reading from.
 * @param width  Number of bytes to read.
 * @param endian Byte order (LE or BE).
 * @return Just(int) on success, Nothing if not enough bytes.
 */
inline HPointer decodeUnsignedInt(void* buf, i64 offset, Width width, Endianness endian) {
    auto v = alloc::byteBufferView(buf);
    size_t w = static_cast<size_t>(width);
    size_t off = static_cast<size_t>(offset);

    if (offset < 0 || off + w > v.length) {
        return alloc::nothing();
    }

    u64 value = 0;
    switch (width) {
        case Width::W8: {
            value = v.data[off];
            break;
        }
        case Width::W16: {
            u16 v16;
            std::memcpy(&v16, v.data + off, 2);
            if (endian == Endianness::BE) v16 = __builtin_bswap16(v16);
            value = v16;
            break;
        }
        case Width::W32: {
            u32 v32;
            std::memcpy(&v32, v.data + off, 4);
            if (endian == Endianness::BE) v32 = __builtin_bswap32(v32);
            value = v32;
            break;
        }
    }

    return alloc::just(alloc::unboxedInt(static_cast<i64>(value)), false);
}

/**
 * Decodes a signed integer from bytes (two's complement).
 */
inline HPointer decodeSignedInt(void* buf, i64 offset, Width width, Endianness endian) {
    auto v = alloc::byteBufferView(buf);
    size_t w = static_cast<size_t>(width);
    size_t off = static_cast<size_t>(offset);

    if (offset < 0 || off + w > v.length) {
        return alloc::nothing();
    }

    i64 signed_value;
    switch (width) {
        case Width::W8:
            signed_value = static_cast<int8_t>(v.data[off]);
            break;
        case Width::W16: {
            u16 v16;
            std::memcpy(&v16, v.data + off, 2);
            if (endian == Endianness::BE) v16 = __builtin_bswap16(v16);
            signed_value = static_cast<int16_t>(v16);
            break;
        }
        case Width::W32: {
            u32 v32;
            std::memcpy(&v32, v.data + off, 4);
            if (endian == Endianness::BE) v32 = __builtin_bswap32(v32);
            signed_value = static_cast<int32_t>(v32);
            break;
        }
    }

    return alloc::just(alloc::unboxedInt(signed_value), false);
}

// ============================================================================
// Encoding - Floats
// ============================================================================

/**
 * Encodes a 32-bit float into bytes.
 */
inline HPointer encodeFloat32(f64 value, Endianness endian) {
    float f = static_cast<float>(value);
    u32 bits;
    std::memcpy(&bits, &f, 4);
    if (endian == Endianness::BE) bits = __builtin_bswap32(bits);
    u8 bytes[4];
    std::memcpy(bytes, &bits, 4);
    return alloc::allocByteBuffer(bytes, 4);
}

/**
 * Encodes a 64-bit float into bytes.
 */
inline HPointer encodeFloat64(f64 value, Endianness endian) {
    u64 bits;
    std::memcpy(&bits, &value, 8);
    if (endian == Endianness::BE) bits = __builtin_bswap64(bits);
    u8 bytes[8];
    std::memcpy(bytes, &bits, 8);
    return alloc::allocByteBuffer(bytes, 8);
}

/**
 * Decodes a 32-bit float from bytes.
 */
inline HPointer decodeFloat32(void* buf, i64 offset, Endianness endian) {
    auto v = alloc::byteBufferView(buf);
    size_t off = static_cast<size_t>(offset);

    if (offset < 0 || off + 4 > v.length) {
        return alloc::nothing();
    }

    u32 bits;
    std::memcpy(&bits, v.data + off, 4);
    if (endian == Endianness::BE) bits = __builtin_bswap32(bits);
    float f;
    std::memcpy(&f, &bits, 4);

    return alloc::just(alloc::unboxedFloat(static_cast<f64>(f)), false);
}

/**
 * Decodes a 64-bit float from bytes.
 */
inline HPointer decodeFloat64(void* buf, i64 offset, Endianness endian) {
    auto v = alloc::byteBufferView(buf);
    size_t off = static_cast<size_t>(offset);

    if (offset < 0 || off + 8 > v.length) {
        return alloc::nothing();
    }

    u64 bits;
    std::memcpy(&bits, v.data + off, 8);
    if (endian == Endianness::BE) bits = __builtin_bswap64(bits);
    f64 d;
    std::memcpy(&d, &bits, 8);

    return alloc::just(alloc::unboxedFloat(d), false);
}

// ============================================================================
// String Conversion
// ============================================================================

/**
 * Decodes a ByteBuffer as UTF-8 into an ElmString.
 * Returns Just(string) on success, Nothing on invalid UTF-8.
 */
HPointer decodeUtf8(void* buf);

/**
 * Encodes an ElmString as UTF-8 into a ByteBuffer.
 */
HPointer encodeUtf8(void* str);

// ============================================================================
// List Conversion
// ============================================================================

/**
 * Converts a ByteBuffer to a list of integers (0-255).
 */
HPointer toList(void* buf);

// ============================================================================
// Concatenation
// ============================================================================

/**
 * Appends two ByteBuffers. Pattern-B for the sub-LOT path, single
 * memcpy each side directly into the freshly-allocated destination.
 * Large-object path goes through allocLargeByteBuffer with both inputs
 * rooted across the (potentially GC-triggering) header+body allocations.
 */
inline HPointer append(void* a, void* b) {
    auto& allocator = Allocator::instance();
    size_t len_a = alloc::byteBufferLength(a);
    size_t len_b = alloc::byteBufferLength(b);

    if (len_a == 0) return allocator.wrap(b);
    if (len_b == 0) return allocator.wrap(a);

    size_t total_len = len_a + len_b;

    HPointer aHP = allocator.wrap(a);
    HPointer bHP = allocator.wrap(b);

    // Allocate via the LOT-aware blank helper; both inputs rooted across
    // the (potentially multi-step) allocation.
    alloc::BlankByteBuffer dst;
    {
        HPointer roots[2] = { aHP, bHP };
        StackRootRangeGuard guard(roots, 2, 0x3);
        dst = alloc::allocByteBufferBlank(total_len);
        aHP = roots[0];
        bHP = roots[1];
    }

    auto va = alloc::byteBufferView(allocator.resolve(aHP));
    auto vb = alloc::byteBufferView(allocator.resolve(bHP));
    std::memcpy(dst.bytes, va.data, len_a);
    std::memcpy(dst.bytes + len_a, vb.data, len_b);
    return dst.hp;
}

/**
 * Concatenates a list of ByteBuffers.
 */
HPointer concat(HPointer bufferList);

// ============================================================================
// Utilities
// ============================================================================

/**
 * Converts a ByteBuffer to a std::vector of bytes.
 */
inline std::vector<u8> toVector(void* buf) {
    auto v = alloc::byteBufferView(buf);
    return std::vector<u8>(v.data, v.data + v.length);
}

/**
 * Returns true if two ByteBuffers have equal contents.
 */
inline bool equal(void* a, void* b) {
    auto va = alloc::byteBufferView(a);
    auto vb = alloc::byteBufferView(b);
    if (va.length != vb.length) return false;
    return std::memcmp(va.data, vb.data, va.length) == 0;
}

/**
 * Computes a simple hash of a ByteBuffer (for debugging/testing).
 */
inline u32 hash(void* buf) {
    auto v = alloc::byteBufferView(buf);
    u32 h = 0;
    for (size_t i = 0; i < v.length; ++i) {
        h = h * 31 + v.data[i];
    }
    return h;
}

// ============================================================================
// Base64 Encoding
// ============================================================================

/**
 * Encodes a ByteBuffer as Base64.
 * Returns an ElmString containing the Base64-encoded data.
 */
HPointer toBase64(void* buf);

/**
 * Decodes a Base64 ElmString into a ByteBuffer.
 * Returns Just(bytes) on success, Nothing on invalid Base64.
 */
HPointer fromBase64(void* str);

// ============================================================================
// Hex Encoding
// ============================================================================

/**
 * Encodes a ByteBuffer as lowercase hexadecimal.
 * Returns an ElmString like "48656c6c6f".
 */
HPointer toHex(void* buf);

/**
 * Decodes a hexadecimal ElmString into a ByteBuffer.
 * Returns Just(bytes) on success, Nothing on invalid hex.
 */
HPointer fromHex(void* str);

} // namespace BytesOps
} // namespace Elm

#endif // ECO_BYTES_OPS_H
