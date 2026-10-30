// The kernels behind Elm's `Bytes` type: building a Bytes value, reading integers, floats and text out of one,
// joining and cutting them, and converting them to and from lists, Base64 and hexadecimal.
//
// A Bytes value is an immutable sequence of bytes. On the heap it takes one of three forms: a `ByteBuffer`, which
// holds its bytes inline; a large buffer, a `LargeByteHeader` whose bytes are in a separate pinned body; and a
// slice, an `ElmByteBufferSlice` that names a range of another buffer's bytes. The empty Bytes is never an object.
// It is the Empty constant that `alloc::emptyBytes` returns.
//
// A parameter that takes a Bytes value as a `void*` takes the object in any of the three forms, or null for the
// empty Bytes, which is what `alloc::resolveBytesOrNull` gives for it. Every function that reads a Bytes argument
// reads it through `alloc::byteBufferView` or `alloc::byteBufferLength`, so none depends on the form. A parameter
// that takes a String as a `void*` likewise takes any String form, or null for the empty String.
//
// A decoder returns an Elm `Maybe`: `Just` the value, or `Nothing` when the input is too short or not well formed.
// Offsets and indexes count bytes from 0.
//
// A function that returns an `HPointer` may allocate, and so may run a collection that moves objects. Each one,
// apart from `fromData`, reads, copies or roots its own arguments before it allocates. A raw pointer the caller
// holds, an argument included, may be stale afterwards. The functions that return a number, a `bool` or a
// `std::vector` do not allocate on the Elm heap.

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

/**
 * The order in which the bytes of a multi-byte number are laid out. A one-byte number has only one order, and
 * its encoders and decoders ignore this.
 */
enum class Endianness {
    LE,  // Least significant byte first.
    BE   // Most significant byte first.
};

// ============================================================================
// Width for integer encoding
// ============================================================================

/**
 * How many bytes an encoded integer occupies. Each enumerator's value is that number of bytes, and the integer
 * codecs use it as a byte count.
 */
enum class Width {
    W8   = 1,
    W16  = 2,
    W32  = 4,
};

// ============================================================================
// Creation
// ============================================================================

// Returns the empty Bytes, the Empty constant. Does not allocate.
inline HPointer empty() {
    return alloc::allocByteBuffer(nullptr, 0);
}

// Returns a Bytes value holding one byte per element of the Elm list `list`, in order. Each byte is the low 8
// bits of the element's slot read as an Int, so a value outside 0 to 255 wraps. An empty list gives the empty
// Bytes.
HPointer fromList(HPointer list);

// Returns a Bytes value holding a copy of the `length` bytes at `data`, or the empty Bytes when `length` is 0.
//
// The bytes are copied after any collection the allocation runs, so `data` must not point into the collected
// heap, as `alloc::allocByteBuffer` requires.
inline HPointer fromData(const u8* data, size_t length) {
    return alloc::allocByteBuffer(data, length);
}

// Returns a Bytes value holding a copy of the bytes of `vec`, or the empty Bytes when it is empty.
inline HPointer fromVector(const std::vector<u8>& vec) {
    return alloc::allocByteBuffer(vec.data(), vec.size());
}

// Returns the UTF-8 encoding of the String `str`, exactly as `encodeUtf8` does.
HPointer fromString(void* str);

// ============================================================================
// Access
// ============================================================================

// Returns the number of bytes in `buf`.
inline i64 length(void* buf) {
    return static_cast<i64>(alloc::byteBufferLength(buf));
}

// Returns the byte of `buf` at `index`, from 0 to 255, or -1 when `index` is negative or not below its length.
inline i64 getAt(void* buf, i64 index) {
    auto v = alloc::byteBufferView(buf);
    if (index < 0 || static_cast<size_t>(index) >= v.length) {
        return -1;
    }
    return static_cast<i64>(v.data[index]);
}

// Returns the bytes of `buf` from `start` up to but not including `end`.
//
// Each bound is first clamped to between 0 and the length of `buf`; a negative bound means 0, not a count from
// the end. When `start` is not below `end` the result is the empty Bytes. Otherwise it is what
// `alloc::makeByteBufferSlice` gives: a copy for a range shorter than `MAKE_BYTEBUFFER_SLICE_MIN_LEN` bytes, and
// otherwise a slice that refers to the bytes of `buf` (or of its base, when `buf` is a slice) without copying
// them.
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

// Returns a Bytes value of `width` bytes holding the low `width` bytes of `value`, in the order `endian`
// gives. Higher bytes of `value` are dropped.
inline HPointer encodeUnsignedInt(u64 value, Width width, Endianness endian) {
    size_t w = static_cast<size_t>(width);
    u8 bytes[4];

    // The value is copied out in host order and byte-swapped only for BE, which is right only on a little-endian
    // host.
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

// Returns a Bytes value of `width` bytes holding the low `width` bytes of the two's complement form of
// `value`, in the order `endian` gives, as `encodeUnsignedInt` does.
inline HPointer encodeSignedInt(i64 value, Width width, Endianness endian) {
    return encodeUnsignedInt(static_cast<u64>(value), width, endian);
}

// Returns `Just` the unsigned integer in the `width` bytes of `buf` starting at `offset`, read in the order
// `endian` gives, or `Nothing` when `offset` is negative or fewer than `width` bytes follow it. The `Just`
// holds an unboxed Int.
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

// Returns `Just` the two's complement integer in the `width` bytes of `buf` starting at `offset`, read in the
// order `endian` gives and sign-extended, or `Nothing` as `decodeUnsignedInt` does. The `Just` holds an
// unboxed Int.
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

// Returns a Bytes value of 4 bytes holding `value`, converted to a 32-bit IEEE 754 float, in the order
// `endian` gives.
inline HPointer encodeFloat32(f64 value, Endianness endian) {
    float f = static_cast<float>(value);
    u32 bits;
    std::memcpy(&bits, &f, 4);
    if (endian == Endianness::BE) bits = __builtin_bswap32(bits);
    u8 bytes[4];
    std::memcpy(bytes, &bits, 4);
    return alloc::allocByteBuffer(bytes, 4);
}

// Returns a Bytes value of 8 bytes holding `value` as a 64-bit IEEE 754 float, in the order `endian` gives.
inline HPointer encodeFloat64(f64 value, Endianness endian) {
    u64 bits;
    std::memcpy(&bits, &value, 8);
    if (endian == Endianness::BE) bits = __builtin_bswap64(bits);
    u8 bytes[8];
    std::memcpy(bytes, &bits, 8);
    return alloc::allocByteBuffer(bytes, 8);
}

// Returns `Just` the 32-bit IEEE 754 float in the 4 bytes of `buf` starting at `offset`, read in the order
// `endian` gives and widened to 64 bits, or `Nothing` when `offset` is negative or fewer than 4 bytes follow
// it.
//
// The `Just` is built by `alloc::just` with `is_boxed` false, so its slot is marked with the Int kind although
// it holds a Float's bits.
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

    return alloc::justKind(alloc::unboxedFloat(static_cast<f64>(f)), 2);
}

// Returns `Just` the 64-bit IEEE 754 float in the 8 bytes of `buf` starting at `offset`, read in the order
// `endian` gives, or `Nothing` when `offset` is negative or fewer than 8 bytes follow it.
//
// As in `decodeFloat32`, the `Just`'s slot is marked with the Int kind although it holds a Float's bits.
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

    return alloc::justKind(alloc::unboxedFloat(d), 2);
}

// ============================================================================
// String Conversion
// ============================================================================

// Returns `Just` the String whose UTF-8 encoding is the bytes of `buf`, or `Nothing` when they are not well
// formed. A non-empty String is a UTF-16 String, never one of the UTF-8
// forms, and empty input gives `Just` the empty String.
//
// The check is only of the shape of each sequence: a lead byte of the form 0xxxxxxx, 110xxxxx, 1110xxxx or
// 11110xxx followed by that many continuation bytes of the form 10xxxxxx, all before the end. Overlong forms,
// encoded surrogates and lead bytes 0xF5 to 0xF7 pass it. A decoded value above 0xFFFF is written as a
// surrogate pair; one above 0x10FFFF gives two units that are not a valid pair.
HPointer decodeUtf8(void* buf);

// Returns a Bytes value holding the UTF-8 encoding of the String `str`, or the empty Bytes for an empty or null
// `str`.
//
// A high surrogate followed by a low one is encoded as the code point the pair stands for. Any other surrogate
// unit is encoded on its own as a three-byte sequence, which is not well-formed UTF-8.
HPointer encodeUtf8(void* str);

// ============================================================================
// List Conversion
// ============================================================================

// Returns an Elm list of the bytes of `buf`, in order, each an unboxed Int from 0 to 255.
HPointer toList(void* buf);

// ============================================================================
// Concatenation
// ============================================================================

// Returns the bytes of `a` followed by those of `b`.
//
// When either is empty the result is the other one itself, not a copy, and when both are empty it is the empty
// Bytes. Otherwise the result is a new buffer holding a copy of both, never a slice.
inline HPointer append(void* a, void* b) {
    auto& allocator = Allocator::instance();
    size_t len_a = alloc::byteBufferLength(a);
    size_t len_b = alloc::byteBufferLength(b);

    // A null side is the empty-Bytes constant; never wrap(nullptr).
    if (len_a == 0) return b ? allocator.wrap(b) : alloc::emptyBytes();
    if (len_b == 0) return allocator.wrap(a);

    size_t total_len = len_a + len_b;

    HPointer aHP = allocator.wrap(a);
    HPointer bHP = allocator.wrap(b);

    alloc::BlankByteBuffer dst;
    {
        HPointer roots[2] = { aHP, bHP };
        StackRootRangeGuard guard(roots, 2, 0x3);
        dst = alloc::allocByteBufferBlank(total_len);
        aHP = roots[0];
        bHP = roots[1];
    }

    // Nothing allocates from here on, so dst.bytes and both views stay valid for the copies.
    auto va = alloc::byteBufferView(allocator.resolve(aHP));
    auto vb = alloc::byteBufferView(allocator.resolve(bHP));
    std::memcpy(dst.bytes, va.data, len_a);
    std::memcpy(dst.bytes + len_a, vb.data, len_b);
    return dst.hp;
}

// Returns the bytes of every Bytes value in the Elm list `bufferList`, joined in order, as a new buffer, or the
// empty Bytes when they hold no bytes between them. Each element must be a Bytes value; an element that is the
// Empty constant contributes nothing.
HPointer concat(HPointer bufferList);

// ============================================================================
// Utilities
// ============================================================================

// Returns a copy of the bytes of `buf`.
inline std::vector<u8> toVector(void* buf) {
    auto v = alloc::byteBufferView(buf);
    return std::vector<u8>(v.data, v.data + v.length);
}

// Returns whether `a` and `b` hold the same bytes, whatever their forms. Null equals any Bytes value of length
// 0.
inline bool equal(void* a, void* b) {
    auto va = alloc::byteBufferView(a);
    auto vb = alloc::byteBufferView(b);
    if (va.length != vb.length) return false;
    return std::memcmp(va.data, vb.data, va.length) == 0;
}

// Returns a 32-bit hash of the bytes of `buf`: starting from 0, each byte in turn is added to the running value
// multiplied by 31, modulo 2^32. Bytes values that hold the same bytes hash alike whatever their forms.
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

// Returns the bytes of `buf` as a String in Base64, with the alphabet `A`-`Z`, `a`-`z`, `0`-`9`, `+`, `/` and
// `=` padding, or the empty String when `buf` is empty. A non-empty result is a UTF-16 String.
HPointer toBase64(void* buf);

// Returns `Just` the bytes that the Base64 String `str` encodes, or `Nothing` when it is not Base64. A null or
// empty `str` gives `Just` the empty Bytes.
//
// `str` must have a multiple of 4 units, each from the alphabet `toBase64` uses, and the first two of each group
// of 4 must not be `=`. The check goes no further: `=` is accepted in the last two places of any group, not only
// the last, and bits left over by padding need not be zero. A group whose third unit is `=` and whose fourth is
// not gives two bytes, the second built from the fourth unit alone.
HPointer fromBase64(void* str);

// ============================================================================
// Hex Encoding
// ============================================================================

// Returns the bytes of `buf` as a String of lowercase hexadecimal digits, two per byte, high digit first, or the
// empty String when `buf` is empty. A non-empty result is a UTF-16 String.
HPointer toHex(void* buf);

// Returns `Just` the bytes that the hexadecimal String `str` encodes, two digits per byte with the high digit
// first, or `Nothing` when it has an odd number of units or a unit that is not a hexadecimal digit. Digits may
// be upper or lower case. A null or empty `str` gives `Just` the empty Bytes.
HPointer fromHex(void* str);

} // namespace BytesOps
} // namespace Elm

#endif // ECO_BYTES_OPS_H
