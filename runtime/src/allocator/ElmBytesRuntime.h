/**
 * Byte Fusion Runtime ABI for Elm Compiler.
 *
 * This header defines the C ABI functions used by the bf MLIR dialect lowering.
 * All heap values are represented as u64 (eco.value) at the ABI boundary.
 * Internal pointer conversion happens only inside ElmBytesRuntime.cpp.
 *
 * These functions are the ONLY code allowed to access ByteBuffer/ElmString
 * header layout directly. Generated MLIR/LLVM code must call these helpers
 * instead of using GEPs into the structures.
 */

#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint8_t  u8;
typedef uint32_t u32;
typedef uint64_t u64;  // eco.value representation

// ============================================================================
// ByteBuffer operations (heap values are u64)
// ============================================================================

/**
 * Allocate ByteBuffer with byteCount bytes.
 * Returns eco.value (u64) representing the allocated ByteBuffer.
 */
u64 elm_alloc_bytebuffer(u32 byteCount);

/**
 * Return ByteBuffer byte length.
 * Takes eco.value (u64) representing a ByteBuffer.
 */
u32 elm_bytebuffer_len(u64 bb);

/**
 * Return pointer to first payload byte.
 * Takes eco.value (u64) representing a ByteBuffer.
 * Returns raw pointer (for cursor setup only - not an eco.value).
 */
u8* elm_bytebuffer_data(u64 bb);

// ============================================================================
// String operations (heap values are u64)
// ============================================================================

/**
 * Return UTF-8 byte width of an ElmString.
 * Takes eco.value (u64) representing an ElmString.
 * Returns the number of bytes needed to represent the string in UTF-8.
 */
u32 elm_utf8_width(u64 elmString);

/**
 * Copy ElmString as UTF-8 bytes to dst buffer.
 * Takes eco.value (u64) representing an ElmString and a destination buffer.
 * Returns number of bytes written.
 *
 * IMPORTANT: Caller must ensure dst has at least elm_utf8_width(elmString) bytes.
 */
u32 elm_utf8_copy(u64 elmString, u8* dst);

/**
 * Decode UTF-8 bytes into an ElmString.
 * Returns eco.value (u64) representing the ElmString, or 0 on failure.
 *
 * Failure semantics: Returns 0 on invalid UTF-8 input.
 * eco.value == 0 is guaranteed to never represent a valid Elm heap value
 * (null pointer is invalid in the Elm runtime).
 */
u64 elm_utf8_decode(const u8* src, u32 len);

// ============================================================================
// Maybe operations (heap values are u64)
// ============================================================================

/**
 * Return Nothing as eco.value (u64).
 * Returns the embedded constant for Nothing.
 */
u64 elm_maybe_nothing(void);

/**
 * Return Just(value) as eco.value (u64).
 * Takes the value to wrap and returns Just containing that value.
 */
u64 elm_maybe_just(u64 value);

// ============================================================================
// List operations (heap values are u64)
// ============================================================================

/**
 * Reverse a list.
 * Takes eco.value (u64) representing a list.
 * Returns eco.value (u64) representing the reversed list.
 *
 * Used by fused byte decoders to reverse the accumulator after loop decode.
 */
u64 elm_list_reverse(u64 list);

#ifdef __cplusplus
}
#endif
