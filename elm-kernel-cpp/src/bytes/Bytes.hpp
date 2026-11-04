#ifndef ECO_BYTES_HPP
#define ECO_BYTES_HPP

// A C++ namespace API for elm/bytes over the runtime's ByteBuffer values. Nothing calls it.
//
// It is compiled into the Bytes kernel library, but Elm code reaches elm/bytes only through the
// C-linkage kernel exports declared in `KernelExports.h` and defined in `BytesExports.cpp`. Those
// follow different conventions from the functions here, so nothing below describes what Elm code
// gets:
//
// - A read here returns `Just(Tuple2(value, newOffset))`, or Nothing when the read would run past
//   the end of the buffer. The exported reads return `Tuple2(newOffset, value)`, the other way
//   round, and report a failed read by throwing `Elm::BytesDecodeFailure`.
// - A write here returns a finished ByteBuffer holding the encoded value. The exported writes
//   return a node of the `Bytes.Encode.Encoder` tree, and only the exported encode turns a tree
//   into bytes.
// - `decode` here always returns Nothing. The exported decode runs the decoder.
//
// Endianness parameters are a C++ `bool` here, true meaning little-endian.

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"

namespace Elm::Kernel::Bytes {

// ============================================================================
// Basic Operations
// ============================================================================

/// Returns the number of bytes in `bytes`, a ByteBuffer.
i64 width(void* bytes);

/// Returns the `Endianness` value of the host: the null-cons word for ctor 0 (`LE`) on a
/// little-endian host, and for ctor 1 (`BE`) on a big-endian one.
HPointer getHostEndianness();

/// Returns the number of bytes `str`, a String, occupies once encoded as UTF-8.
///
/// A surrogate that is not part of a high-low pair counts as 3 bytes.
i64 getStringWidth(void* str);

// ============================================================================
// Decoding
// ============================================================================

/// Returns Nothing, whatever `decoder` and `bytes` are. It does not run the decoder.
HPointer decode(void* decoder, void* bytes);

/// Returns Nothing.
HPointer decodeFailure();

// ============================================================================
// Read Operations
// ============================================================================

// Each read takes the ByteBuffer `bytes` and the byte `offset` to read at, and returns
// `Just(Tuple2(value, newOffset))`, where `newOffset` is `offset` plus the width read, or Nothing
// when the read does not fit, as `BytesOps::decodeUnsignedInt` decides for the numeric reads. The
// order is the reverse of the exported reads.

/// Reads a signed 8-bit integer.
HPointer read_i8(void* bytes, i64 offset);
/// Reads a signed 16-bit integer.
HPointer read_i16(bool littleEndian, void* bytes, i64 offset);
/// Reads a signed 32-bit integer.
HPointer read_i32(bool littleEndian, void* bytes, i64 offset);
/// Reads an unsigned 8-bit integer.
HPointer read_u8(void* bytes, i64 offset);
/// Reads an unsigned 16-bit integer.
HPointer read_u16(bool littleEndian, void* bytes, i64 offset);
/// Reads an unsigned 32-bit integer.
HPointer read_u32(bool littleEndian, void* bytes, i64 offset);
/// Reads a 32-bit float, widened to a Float.
HPointer read_f32(bool littleEndian, void* bytes, i64 offset);
/// Reads a 64-bit float.
HPointer read_f64(bool littleEndian, void* bytes, i64 offset);
/// Reads the next `length` bytes, as `BytesOps::slice` returns them.
///
/// A negative `offset` gives Nothing; a negative `length` is not checked for.
HPointer read_bytes(i64 length, void* bytes, i64 offset);
// There is no string read here. The string decoder is the exported `Bytes.read_string`.

// ============================================================================
// Write Operations
// ============================================================================

// Each numeric write returns a new ByteBuffer holding `value` encoded at the width the name gives.

/// Encodes a signed 8-bit integer.
HPointer write_i8(i64 value);
/// Encodes a signed 16-bit integer.
HPointer write_i16(bool littleEndian, i64 value);
/// Encodes a signed 32-bit integer.
HPointer write_i32(bool littleEndian, i64 value);
/// Encodes an unsigned 8-bit integer.
HPointer write_u8(i64 value);
/// Encodes an unsigned 16-bit integer.
HPointer write_u16(bool littleEndian, i64 value);
/// Encodes an unsigned 32-bit integer.
HPointer write_u32(bool littleEndian, i64 value);
/// Encodes a 32-bit float.
HPointer write_f32(bool littleEndian, f64 value);
/// Encodes a 64-bit float.
HPointer write_f64(bool littleEndian, f64 value);
/// Returns `bytes` itself, which is not copied, or the empty Bytes when `bytes` is null.
HPointer write_bytes(void* bytes);
/// Returns `str` encoded as UTF-8, as `BytesOps::encodeUtf8` does.
HPointer write_string(void* str);

// ============================================================================
// Encoding
// ============================================================================

/// Returns the Bytes values of the List `encoderList` joined in order, as `BytesOps::concat` does.
HPointer encode(HPointer encoderList);

} // namespace Elm::Kernel::Bytes

#endif // ECO_BYTES_HPP
