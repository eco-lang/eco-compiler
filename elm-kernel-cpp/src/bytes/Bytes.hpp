#ifndef ELM_KERNEL_BYTES_HPP
#define ELM_KERNEL_BYTES_HPP

/**
 * Elm Kernel Bytes Module - Runtime Heap Integration
 *
 * This module provides binary data encoding/decoding using the GC-managed
 * ByteBuffer type from the runtime heap.
 */

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"

namespace Elm::Kernel::Bytes {

// ============================================================================
// Basic Operations
// ============================================================================

/**
 * Returns the width (length) of a ByteBuffer.
 */
i64 width(void* bytes);

/**
 * Get host machine endianness - returns LE (ctor 0) or BE (ctor 1).
 */
HPointer getHostEndianness();

/**
 * Get the width needed to encode a string as UTF-8.
 */
i64 getStringWidth(void* str);

// ============================================================================
// Decoding
// ============================================================================

/**
 * Decode bytes with a decoder - returns Maybe value.
 * Note: Full decoder implementation is complex, this is a stub.
 */
HPointer decode(void* decoder, void* bytes);

/**
 * Return Nothing to indicate decode failure.
 */
HPointer decodeFailure();

// ============================================================================
// Read Operations
// All return Just(Tuple2(value, newOffset)) or Nothing on failure
// ============================================================================

HPointer read_i8(void* bytes, i64 offset);
HPointer read_i16(bool littleEndian, void* bytes, i64 offset);
HPointer read_i32(bool littleEndian, void* bytes, i64 offset);
HPointer read_u8(void* bytes, i64 offset);
HPointer read_u16(bool littleEndian, void* bytes, i64 offset);
HPointer read_u32(bool littleEndian, void* bytes, i64 offset);
HPointer read_f32(bool littleEndian, void* bytes, i64 offset);
HPointer read_f64(bool littleEndian, void* bytes, i64 offset);
HPointer read_bytes(i64 length, void* bytes, i64 offset);
HPointer read_string(i64 length, void* bytes, i64 offset);

// ============================================================================
// Write Operations
// All return a ByteBuffer containing the encoded value
// ============================================================================

HPointer write_i8(i64 value);
HPointer write_i16(bool littleEndian, i64 value);
HPointer write_i32(bool littleEndian, i64 value);
HPointer write_u8(i64 value);
HPointer write_u16(bool littleEndian, i64 value);
HPointer write_u32(bool littleEndian, i64 value);
HPointer write_f32(bool littleEndian, f64 value);
HPointer write_f64(bool littleEndian, f64 value);
HPointer write_bytes(void* bytes);
HPointer write_string(void* str);

// ============================================================================
// Encoding
// ============================================================================

/**
 * Concatenate a list of ByteBuffers into one.
 */
HPointer encode(HPointer encoderList);

} // namespace Elm::Kernel::Bytes

#endif // ELM_KERNEL_BYTES_HPP
