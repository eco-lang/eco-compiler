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
 * Returns the number of bytes in a ByteBuffer.
 */
inline i64 length(void* buf) {
    ByteBuffer* b = static_cast<ByteBuffer*>(buf);
    return static_cast<i64>(b->header.size);
}

/**
 * Returns the byte at a given index (0-based).
 * Returns -1 if index is out of bounds.
 */
inline i64 getAt(void* buf, i64 index) {
    ByteBuffer* b = static_cast<ByteBuffer*>(buf);
    if (index < 0 || static_cast<size_t>(index) >= b->header.size) {
        return -1;
    }
    return static_cast<i64>(b->bytes[index]);
}

/**
 * Extracts a slice from start (inclusive) to end (exclusive).
 */
inline HPointer slice(void* buf, i64 start, i64 end) {
    ByteBuffer* b = static_cast<ByteBuffer*>(buf);
    i64 len = static_cast<i64>(b->header.size);

    // Clamp to bounds
    start = std::max(i64(0), std::min(start, len));
    end = std::max(i64(0), std::min(end, len));

    if (start >= end) return empty();

    size_t slice_len = static_cast<size_t>(end - start);
    return alloc::allocByteBuffer(b->bytes + start, slice_len);
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

    if (endian == Endianness::LE) {
        for (size_t i = 0; i < w; ++i) {
            bytes[i] = static_cast<u8>((value >> (i * 8)) & 0xFF);
        }
    } else {
        for (size_t i = 0; i < w; ++i) {
            bytes[w - 1 - i] = static_cast<u8>((value >> (i * 8)) & 0xFF);
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
    ByteBuffer* b = static_cast<ByteBuffer*>(buf);
    size_t w = static_cast<size_t>(width);
    size_t off = static_cast<size_t>(offset);

    if (offset < 0 || off + w > b->header.size) {
        return alloc::nothing();
    }

    u64 value = 0;
    if (endian == Endianness::LE) {
        for (size_t i = 0; i < w; ++i) {
            value |= static_cast<u64>(b->bytes[off + i]) << (i * 8);
        }
    } else {
        for (size_t i = 0; i < w; ++i) {
            value |= static_cast<u64>(b->bytes[off + i]) << ((w - 1 - i) * 8);
        }
    }

    return alloc::just(alloc::unboxedInt(static_cast<i64>(value)), false);
}

/**
 * Decodes a signed integer from bytes (two's complement).
 */
inline HPointer decodeSignedInt(void* buf, i64 offset, Width width, Endianness endian) {
    ByteBuffer* b = static_cast<ByteBuffer*>(buf);
    size_t w = static_cast<size_t>(width);
    size_t off = static_cast<size_t>(offset);

    if (offset < 0 || off + w > b->header.size) {
        return alloc::nothing();
    }

    u64 value = 0;
    if (endian == Endianness::LE) {
        for (size_t i = 0; i < w; ++i) {
            value |= static_cast<u64>(b->bytes[off + i]) << (i * 8);
        }
    } else {
        for (size_t i = 0; i < w; ++i) {
            value |= static_cast<u64>(b->bytes[off + i]) << ((w - 1 - i) * 8);
        }
    }

    // Sign extend
    i64 signed_value;
    switch (width) {
        case Width::W8:
            signed_value = static_cast<int8_t>(value);
            break;
        case Width::W16:
            signed_value = static_cast<int16_t>(value);
            break;
        case Width::W32:
            signed_value = static_cast<int32_t>(value);
            break;
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
    u8 bytes[4];

    std::memcpy(bytes, &f, 4);

    // Swap bytes if needed
    if (endian == Endianness::BE) {
        std::swap(bytes[0], bytes[3]);
        std::swap(bytes[1], bytes[2]);
    }

    return alloc::allocByteBuffer(bytes, 4);
}

/**
 * Encodes a 64-bit float into bytes.
 */
inline HPointer encodeFloat64(f64 value, Endianness endian) {
    u8 bytes[8];

    std::memcpy(bytes, &value, 8);

    // Swap bytes if needed
    if (endian == Endianness::BE) {
        std::swap(bytes[0], bytes[7]);
        std::swap(bytes[1], bytes[6]);
        std::swap(bytes[2], bytes[5]);
        std::swap(bytes[3], bytes[4]);
    }

    return alloc::allocByteBuffer(bytes, 8);
}

/**
 * Decodes a 32-bit float from bytes.
 */
inline HPointer decodeFloat32(void* buf, i64 offset, Endianness endian) {
    ByteBuffer* b = static_cast<ByteBuffer*>(buf);
    size_t off = static_cast<size_t>(offset);

    if (offset < 0 || off + 4 > b->header.size) {
        return alloc::nothing();
    }

    u8 bytes[4];
    std::memcpy(bytes, b->bytes + off, 4);

    // Swap bytes if needed
    if (endian == Endianness::BE) {
        std::swap(bytes[0], bytes[3]);
        std::swap(bytes[1], bytes[2]);
    }

    float f;
    std::memcpy(&f, bytes, 4);

    return alloc::just(alloc::unboxedFloat(static_cast<f64>(f)), false);
}

/**
 * Decodes a 64-bit float from bytes.
 */
inline HPointer decodeFloat64(void* buf, i64 offset, Endianness endian) {
    ByteBuffer* b = static_cast<ByteBuffer*>(buf);
    size_t off = static_cast<size_t>(offset);

    if (offset < 0 || off + 8 > b->header.size) {
        return alloc::nothing();
    }

    u8 bytes[8];
    std::memcpy(bytes, b->bytes + off, 8);

    // Swap bytes if needed
    if (endian == Endianness::BE) {
        std::swap(bytes[0], bytes[7]);
        std::swap(bytes[1], bytes[6]);
        std::swap(bytes[2], bytes[5]);
        std::swap(bytes[3], bytes[4]);
    }

    f64 d;
    std::memcpy(&d, bytes, 8);

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
 * Appends two ByteBuffers.
 */
inline HPointer append(void* a, void* b) {
    ByteBuffer* ba = static_cast<ByteBuffer*>(a);
    ByteBuffer* bb = static_cast<ByteBuffer*>(b);

    size_t len_a = ba->header.size;
    size_t len_b = bb->header.size;

    if (len_a == 0) return Allocator::instance().wrap(b);
    if (len_b == 0) return Allocator::instance().wrap(a);

    size_t total_len = len_a + len_b;
    size_t total_size = sizeof(ByteBuffer) + total_len;
    total_size = (total_size + 7) & ~7;

    auto& allocator = Allocator::instance();
    ByteBuffer* result = static_cast<ByteBuffer*>(allocator.allocate(total_size, Tag_ByteBuffer));
    result->header.size = static_cast<u32>(total_len);

    std::memcpy(result->bytes, ba->bytes, len_a);
    std::memcpy(result->bytes + len_a, bb->bytes, len_b);

    return allocator.wrap(result);
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
    ByteBuffer* b = static_cast<ByteBuffer*>(buf);
    return std::vector<u8>(b->bytes, b->bytes + b->header.size);
}

/**
 * Returns true if two ByteBuffers have equal contents.
 */
inline bool equal(void* a, void* b) {
    ByteBuffer* ba = static_cast<ByteBuffer*>(a);
    ByteBuffer* bb = static_cast<ByteBuffer*>(b);

    if (ba->header.size != bb->header.size) return false;

    return std::memcmp(ba->bytes, bb->bytes, ba->header.size) == 0;
}

/**
 * Computes a simple hash of a ByteBuffer (for debugging/testing).
 */
inline u32 hash(void* buf) {
    ByteBuffer* b = static_cast<ByteBuffer*>(buf);
    u32 h = 0;
    for (size_t i = 0; i < b->header.size; ++i) {
        h = h * 31 + b->bytes[i];
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
